import AVFoundation
import CoreAudio
import Foundation

/// Raised when the system-audio capture cannot be set up or started. Carries
/// the failing Core Audio call and its `OSStatus` so the Dart side can show
/// something actionable.
public struct SystemAudioCaptureFailure: Error, CustomStringConvertible {
    public let operation: String
    public let status: OSStatus

    public var description: String {
        "\(operation) failed (OSStatus \(status))"
    }
}

/// Captures the machine's audio mix — every process except this one — through
/// a Core Audio process tap (macOS 14.2+) and queues it as mono Float32 frames
/// in an `AudioInputRing`. For a system-audio-only session `AudioIoPlugin`
/// hands that ring to Dart as the input ring; for microphone plus system audio
/// it renders the ring into its mixer through an `AVAudioSourceNode`.
///
/// Topology, per Apple's guidance: a private aggregate device whose main
/// sub-device is the default output device (it supplies the clock) with the
/// tap attached as a sub-tap. A tap-only aggregate produces no samples. The
/// tap is created mono and global, excluding this process, so audio the app
/// itself plays (TTS through the output stream) does not feed back into the
/// capture; if that exclusion cannot be built, `init` throws rather than
/// capture everything. `muteBehavior` stays `.unmuted`: the captured audio
/// keeps playing out of the speakers.
@available(macOS 14.2, *)
public final class SystemAudioTap {
    enum Constants {
        static let aggregateName = "audio_io system audio"
        static let tapName = "audio_io system audio tap"
        static let ioQueueLabel = "com.wearemobilefirst.audio_io.system-audio-tap"
        static let minimumScratchFrames = 4096
    }

    /// Sample rate of the frames written to `ring`, read from the tap's
    /// stream format.
    public let sampleRate: Double

    /// Mono Float32 frames captured from the tap; drained by the plugin's
    /// `AVAudioSourceNode` on the engine render thread.
    public let ring: AudioInputRing

    private let tapID: AudioObjectID
    private let aggregateID: AudioObjectID
    private let tapFormat: AudioStreamBasicDescription
    /// Index of the tap's buffer in the aggregate device's input
    /// `AudioBufferList`: the main sub-device's own input streams (usually
    /// none, but an audio interface may have some) come first, one buffer per
    /// stream, and the tap's stream follows them.
    private let tapBufferIndex: Int
    private let queue = DispatchQueue(label: Constants.ioQueueLabel)
    private var ioProcID: AudioDeviceIOProcID?
    private var monoScratch: UnsafeMutablePointer<Float>
    private var monoScratchCapacity: Int
    /// Fixed table of plane pointers for the planar downmix, sized to the
    /// tap's channel count in `init` so the IO proc never allocates.
    private let planeTable: UnsafeMutablePointer<UnsafePointer<Float>>
    private let planeTableCapacity: Int
    private(set) var isRunning = false

    /// Creates the tap and its aggregate device. Nothing is captured until
    /// `start()`.
    public init(ringCapacity: Int) throws {
        let outputDevice = try Self.defaultOutputDevice()
        let outputUID = try Self.deviceUID(of: outputDevice)
        let subDeviceInputStreams = Self.inputStreamCount(of: outputDevice)

        let description = CATapDescription(
            monoGlobalTapButExcludeProcesses: [try Self.ownProcessObject()])
        description.name = Constants.tapName
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try Self.check(
            AudioHardwareCreateProcessTap(description, &tapID),
            "AudioHardwareCreateProcessTap")

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let format: AudioStreamBasicDescription
        do {
            format = try Self.readFormat(of: tapID)
            guard format.mFormatID == kAudioFormatLinearPCM,
                format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                format.mBitsPerChannel == 32
            else {
                throw SystemAudioCaptureFailure(
                    operation: "kAudioTapPropertyFormat (expected Float32 PCM)",
                    status: OSStatus(kAudioHardwareUnsupportedOperationError))
            }
            let aggregateDescription = Self.aggregateDescription(
                outputDeviceUID: outputUID, tapUUID: description.uuid)
            try Self.check(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary, &aggregateID),
                "AudioHardwareCreateAggregateDevice")
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }

        self.tapID = tapID
        self.aggregateID = aggregateID
        self.tapFormat = format
        self.tapBufferIndex = subDeviceInputStreams
        self.sampleRate = format.mSampleRate
        self.ring = AudioInputRing(minimumCapacity: ringCapacity)
        self.monoScratchCapacity = Constants.minimumScratchFrames
        self.monoScratch = UnsafeMutablePointer<Float>.allocate(
            capacity: Constants.minimumScratchFrames)
        self.planeTableCapacity = max(Int(format.mChannelsPerFrame), 1)
        self.planeTable = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(
            capacity: planeTableCapacity)
    }

    deinit {
        stop()
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
        monoScratch.deallocate()
        planeTable.deallocate()
    }

    /// Installs the IO proc on the aggregate device and starts it. Frames
    /// then arrive on `ring` from the HAL's IO thread.
    public func start() throws {
        if isRunning { return }
        ensureScratch(Self.bufferFrameSize(of: aggregateID))
        var created: AudioDeviceIOProcID?
        try Self.check(
            AudioDeviceCreateIOProcIDWithBlock(&created, aggregateID, queue) {
                [weak self] _, input, _, _, _ in
                self?.capture(input)
            },
            "AudioDeviceCreateIOProcIDWithBlock")
        guard let procID = created else {
            throw SystemAudioCaptureFailure(
                operation: "AudioDeviceCreateIOProcIDWithBlock (no proc id)",
                status: OSStatus(kAudioHardwareUnspecifiedError))
        }
        do {
            try Self.check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
        } catch {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            throw error
        }
        ioProcID = procID
        isRunning = true
    }

    /// Stops delivery and discards anything still queued. The tap and the
    /// aggregate device stay alive for a later `start()`; `deinit` destroys
    /// them.
    public func stop() {
        guard isRunning, let procID = ioProcID else { return }
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        ioProcID = nil
        isRunning = false
        ring.clear()
    }

    // MARK: - IO proc

    /// Runs on the HAL IO thread: picks the tap's buffer(s) out of the
    /// aggregate's input list, folds any channel layout down to mono, and
    /// writes into the lock-protected ring. No allocation on the steady-state
    /// path: the plane table is fixed at `init`, and the mono scratch is sized
    /// to the device's buffer frame size in `start()`; it grows only if a
    /// callback ever exceeds that, which a device with a fixed buffer size
    /// does not do.
    private func capture(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input))
        guard buffers.count > tapBufferIndex else { return }
        let first = buffers[tapBufferIndex]
        guard let data = first.mData?.assumingMemoryBound(to: Float.self) else { return }

        let nonInterleaved = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = max(Int(first.mNumberChannels), 1)
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        guard frames > 0 else { return }

        if channels == 1 && (!nonInterleaved || tapFormat.mChannelsPerFrame <= 1) {
            ring.write(UnsafeBufferPointer(start: data, count: frames))
            return
        }

        ensureScratch(frames)
        if nonInterleaved {
            // One buffer per channel plane, starting at the tap's index.
            let planeCount = min(
                planeTableCapacity, buffers.count - tapBufferIndex)
            var planesFound = 0
            for plane in 0..<planeCount {
                if let planeData = buffers[tapBufferIndex + plane].mData?
                    .assumingMemoryBound(to: Float.self)
                {
                    planeTable[planesFound] = UnsafePointer(planeData)
                    planesFound += 1
                }
            }
            Self.downmix(
                planes: UnsafePointer(planeTable), planeCount: planesFound,
                frames: frames, into: monoScratch)
        } else {
            Self.downmix(
                interleaved: UnsafePointer(data), channels: channels, frames: frames,
                into: monoScratch)
        }
        ring.write(UnsafeBufferPointer(start: monoScratch, count: frames))
    }

    private func ensureScratch(_ frames: Int) {
        if monoScratchCapacity >= frames { return }
        monoScratch.deallocate()
        monoScratch = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        monoScratchCapacity = frames
    }

    // MARK: - Pure helpers (covered by the example's XCTest target)

    /// Averages `channels` interleaved samples per frame into one mono sample.
    public static func downmix(
        interleaved: UnsafePointer<Float>, channels: Int, frames: Int,
        into out: UnsafeMutablePointer<Float>
    ) {
        guard channels > 0 else { return }
        let gain = 1.0 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            let base = frame * channels
            for channel in 0..<channels {
                sum += interleaved[base + channel]
            }
            out[frame] = sum * gain
        }
    }

    /// Averages one sample per plane into one mono sample per frame.
    public static func downmix(
        planes: UnsafePointer<UnsafePointer<Float>>, planeCount: Int, frames: Int,
        into out: UnsafeMutablePointer<Float>
    ) {
        guard planeCount > 0 else { return }
        let gain = 1.0 / Float(planeCount)
        for frame in 0..<frames {
            var sum: Float = 0
            for plane in 0..<planeCount {
                sum += planes[plane][frame]
            }
            out[frame] = sum * gain
        }
    }

    /// Array convenience over the pointer form, for callers off the IO thread.
    public static func downmix(
        planes: [UnsafePointer<Float>], frames: Int, into out: UnsafeMutablePointer<Float>
    ) {
        planes.withUnsafeBufferPointer { table in
            guard let base = table.baseAddress else { return }
            downmix(planes: base, planeCount: table.count, frames: frames, into: out)
        }
    }

    /// The aggregate-device description that pairs the default output device
    /// (as the clock-providing main sub-device) with the tap as a sub-tap.
    /// `kAudioAggregateDeviceTapAutoStartKey` makes the tap run with the
    /// device; drift compensation keeps the two clocks aligned.
    public static func aggregateDescription(
        outputDeviceUID: String, tapUUID: UUID
    ) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: Constants.aggregateName,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                ]
            ],
        ]
    }

    // MARK: - Core Audio property plumbing

    private static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr {
            throw SystemAudioCaptureFailure(operation: operation, status: status)
        }
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector)
        -> AudioObjectPropertyAddress
    {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() throws -> AudioObjectID {
        var address = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device),
            "kAudioHardwarePropertyDefaultOutputDevice")
        guard device != kAudioObjectUnknown else {
            throw SystemAudioCaptureFailure(
                operation: "kAudioHardwarePropertyDefaultOutputDevice (no output device)",
                status: OSStatus(kAudioHardwareBadDeviceError))
        }
        return device
    }

    private static func deviceUID(of device: AudioObjectID) throws -> String {
        var address = globalAddress(kAudioDevicePropertyDeviceUID)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        try check(status, "kAudioDevicePropertyDeviceUID")
        return uid as String
    }

    /// The device's IO buffer size in frames, or the scratch minimum when it
    /// cannot be read.
    private static func bufferFrameSize(of device: AudioObjectID) -> Int {
        var address = globalAddress(kAudioDevicePropertyBufferFrameSize)
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &frames) == noErr
        else {
            return Constants.minimumScratchFrames
        }
        return max(Int(frames), Constants.minimumScratchFrames)
    }

    private static func inputStreamCount(of device: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else {
            return 0
        }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    /// This process's HAL object, for the tap's exclusion list. The HAL only
    /// registers a process once it has touched Core Audio, which the property
    /// reads in `init` do before this runs. An empty exclusion list would
    /// exclude nothing and the app would hear its own output, so a failed
    /// translation fails the start (`SYSTEM_AUDIO_CAPTURE_FAILED`) instead.
    private static func ownProcessObject() throws -> AudioObjectID {
        var pid = ProcessInfo.processInfo.processIdentifier
        var address = globalAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &pid) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pidPointer, &size, &object)
        }
        try check(status, "kAudioHardwarePropertyTranslatePIDToProcessObject")
        guard object != kAudioObjectUnknown else {
            throw SystemAudioCaptureFailure(
                operation: "kAudioHardwarePropertyTranslatePIDToProcessObject (no process object)",
                status: OSStatus(kAudioHardwareBadObjectError))
        }
        return object
    }

    private static func readFormat(of tap: AudioObjectID) throws
        -> AudioStreamBasicDescription
    {
        var address = globalAddress(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format),
            "kAudioTapPropertyFormat")
        return format
    }
}

import AVFoundation
import FlutterMacOS

enum _Constants {
    static let preferedSampleRate = 48000.0
    /// Clients always push mono Float64 at this rate; the source node is
    /// pinned to it and AVAudioEngine converts to the hardware rate, so
    /// Bluetooth (44.1 kHz A2DP, 16-24 kHz HFP input) and other devices
    /// play at correct speed while the engine keeps consuming 48 k/s.
    static let outputContractSampleRate = 48000.0
    static let defaultFrameDuration = 0.003
    static let defaultMaxFrameJitter = 4.0
    static let processingQueueName = "SwiftAudioIoPluginQueue"
    static let ringBufferSize = 2048
}

enum Methods: String {
    case start
    case stop
    case clearOutput
    case requestFrameDuration
    case requestOutputBufferDuration
    case getFrameDuration
    case requestFormat
    case getFormat
}

enum AudioIoError {
    static let permissionDeniedCode = "MICROPHONE_PERMISSION_DENIED"
    static let permissionDeniedMessage = "Microphone permission not granted. This plugin requires microphone access to function. Please request microphone permission using a package like permission_handler before calling start()."
    static let engineStartCode = "ENGINE_START_ERROR"
    static let engineStartMessage = "Failed to start audio engine"
    static let systemAudioUnsupportedCode = "SYSTEM_AUDIO_UNSUPPORTED"
    static let systemAudioUnsupportedMessage = "System audio capture needs macOS 14.2 or newer (Core Audio process taps)."
    static let systemAudioCaptureFailedCode = "SYSTEM_AUDIO_CAPTURE_FAILED"
}

enum Channels: String {
    case methodChannelName = "com.wearemobilefirst.audio_io"
}

enum AudioDataTypes: String {
    case double
    case float
    case int
}

enum _AudioFormat {
    static let deviceSampleRate = "deviceSampleRate"
    static let sampleRate = "sampleRate"
    static let dataType = "type"
    static let channels = "channels"
    static let input = "input"
    static let output = "output"
}

/// Mirrors `AudioIoInputSource` on the Dart side; carried by name in the
/// `start` call's arguments.
enum InputSource: String {
    case microphone
    case systemAudio
    case microphoneAndSystemAudio

    static let argumentKey = "inputSource"

    var usesMicrophone: Bool { self != .systemAudio }
    var usesSystemAudio: Bool { self != .microphone }

    static func from(_ arguments: Any?) -> InputSource {
        guard let map = arguments as? [String: Any],
            let name = map[argumentKey] as? String,
            let source = InputSource(rawValue: name)
        else {
            return .microphone
        }
        return source
    }
}

enum SystemAudioSupport {
    static var isAvailable: Bool {
        if #available(macOS 14.2, *) {
            return true
        }
        return false
    }
}

public class AudioIoPlugin: NSObject, FlutterPlugin {
    /// Set once in `register(with:)`. The `@_cdecl` FFI data-plane exports
    /// (see the free functions at the bottom of this file) resolve the live
    /// plugin instance through this singleton — the Dart side reaches the
    /// rings by process symbol via `DynamicLibrary.process()`, not through the
    /// registrar it never sees.
    static fileprivate(set) weak var shared: AudioIoPlugin?

    let engine = AVAudioEngine()
    /// Sums every capture source (microphone input node, system-audio tap
    /// source node) into the single mono stream the sink node drains.
    var inputConverter = AVAudioMixerNode()
    var _frameDuration = _Constants.defaultFrameDuration
    var _outputBufferDuration: Double?
    var _sampleRate = _Constants.preferedSampleRate
    var _inputSource = InputSource.microphone
    var buffer = AudioOutputRing(minimumCapacity: 2048)
    var inputRing = AudioInputRing(minimumCapacity: 2048)
    /// Guards the `buffer` / `inputRing` *references* — not their contents (the
    /// rings are internally lock-safe). `startInternal` reassigns both to fresh
    /// instances on every start/reset, while the `@_cdecl` FFI exports load
    /// those references from the Dart poll/write isolate, which keeps running
    /// through a route/interruption reset. Without this lock the swap races the
    /// load and can free a ring mid-read or write into the discarded instance.
    private let ringLock = NSLock()
    let maxFrameJitter = _Constants.defaultMaxFrameJitter
    let queue = DispatchQueue(label: _Constants.processingQueueName)
    var _isRunning = false
    var _isPipelineSetup = false
    var _resetting = false

    private var sourceNode: AVAudioSourceNode?
    /// Present only while the pipeline includes system audio. Typed `Any`
    /// because `SystemAudioTap` is gated on macOS 14.2 and stored properties
    /// cannot carry an availability attribute; every use casts under
    /// `#available`.
    private var systemAudioTap: Any?
    private var tapSourceNode: AVAudioSourceNode?

    deinit {
        NotificationCenter.default.removeObserver(self)
        engine.stop()
    }

    private func createSourceNode() -> AVAudioSourceNode {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat64,
            sampleRate: _Constants.outputContractSampleRate, channels: 1,
            interleaved: false)!
        return AVAudioSourceNode(
            format: format,
            renderBlock: { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
                guard let self = self else { return noErr }
                let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buffer in ablPointer {
                    let buf: UnsafeMutableBufferPointer<Double> = UnsafeMutableBufferPointer(
                        buffer)
                    self.buffer.read(into: buf, count: Int(frameCount))
                }
                return noErr
            })
    }

    // Realtime capture path: write the engine's native Float32 samples straight
    // into the lock-free input ring. No `Data` allocation, no buffer pool, no
    // main-thread dispatch, and no per-sample Double conversion on the render
    // thread — the Dart FFI poll loop drains the ring off-thread (see #27).
    private lazy var sinkNode = AVAudioSinkNode { [weak self] _, frames, audioBufferList -> OSStatus in
        guard let self = self else { return noErr }
        guard let ptr = audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else {
            return noErr
        }
        let src = UnsafeBufferPointer(start: ptr, count: Int(frames))
        self.inputRing.write(src)
        return noErr
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: Channels.methodChannelName.rawValue, binaryMessenger: registrar.messenger)
        let instance = AudioIoPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        AudioIoPlugin.shared = instance

        NotificationCenter.default.addObserver(
            instance, selector: #selector(handleConfigChange),
            name: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: instance.engine)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case Methods.start.rawValue:
            start(inputSource: InputSource.from(call.arguments), result: result)
        case Methods.stop.rawValue:
            stop()
            result(nil)
        case Methods.clearOutput.rawValue:
            buffer.clear()
            result(nil)
        case Methods.requestFrameDuration.rawValue:
            if let requested = call.arguments as? Double {
                _frameDuration = requested
                if _isRunning {
                    resetAudio()
                }
            }
            result(nil)
        case Methods.requestOutputBufferDuration.rawValue:
            _outputBufferDuration = call.arguments as? Double
            if _isRunning {
                resetAudio()
            }
            result(nil)
        case Methods.getFrameDuration.rawValue:
            result(_frameDuration)
        case Methods.getFormat.rawValue:
            result(getFormat())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    public func stop() {
        engine.stop()
        _isRunning = false
        buffer.clear()
        inputRing.clear()
        // A tap's aggregate device is bound to the output device that was the
        // default when it was built; tearing the pipeline down here makes the
        // next start rebuild it against whatever is current, and stops the
        // HAL IO proc while nothing is listening.
        if systemAudioTap != nil {
            detachPipeline()
        }
    }

    func start(inputSource: InputSource, result: @escaping FlutterResult) {
        if inputSource.usesSystemAudio && !SystemAudioSupport.isAvailable {
            result(FlutterError(
                code: AudioIoError.systemAudioUnsupportedCode,
                message: AudioIoError.systemAudioUnsupportedMessage,
                details: nil))
            return
        }
        if inputSource != _inputSource {
            // The source fixes the capture graph, so a different one means
            // rebuilding the pipeline from scratch.
            if _isRunning {
                stop()
            }
            if _isPipelineSetup {
                detachPipeline()
            }
            _inputSource = inputSource
        }
        guard inputSource.usesMicrophone else {
            startEngine(result: result)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine(result: result)
        case .notDetermined:
            // permission_handler has no macOS implementation, so the plugin
            // asks itself; the system prompt uses NSMicrophoneUsageDescription.
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.startEngine(result: result)
                    } else {
                        result(Self.permissionDeniedError())
                    }
                }
            }
        case .denied, .restricted:
            result(Self.permissionDeniedError())
        @unknown default:
            startEngine(result: result)
        }
    }

    private static func permissionDeniedError() -> FlutterError {
        FlutterError(
            code: AudioIoError.permissionDeniedCode,
            message: AudioIoError.permissionDeniedMessage,
            details: nil)
    }

    private func startEngine(result: @escaping FlutterResult) {
        do {
            try startInternal()
            result(nil)
        } catch let failure as SystemAudioCaptureFailure {
            result(FlutterError(
                code: AudioIoError.systemAudioCaptureFailedCode,
                message: failure.description,
                details: nil))
        } catch let error as NSError {
            result(FlutterError(
                code: error.domain,
                message: error.localizedDescription,
                details: nil))
        }
    }

    private func outputRingCapacity() -> Int {
        if let seconds = _outputBufferDuration, seconds > 0 {
            return max(
                _Constants.ringBufferSize,
                Int(seconds * _Constants.outputContractSampleRate))
        }
        return max(
            _Constants.ringBufferSize,
            Int(_frameDuration * _Constants.outputContractSampleRate
                * maxFrameJitter))
    }

    private func captureRingCapacity() -> Int {
        max(
            _Constants.ringBufferSize,
            Int(_frameDuration * _sampleRate * maxFrameJitter))
    }

    private func startInternal() throws {
        let newOutputRing = AudioOutputRing(
                minimumCapacity: outputRingCapacity())

        try setupPipelineIfNeeded()

        // Sized to the same jitter budget as the output ring, at the capture
        // rate the pipeline negotiated in setupPipelineIfNeeded().
        let newInputRing = AudioInputRing(minimumCapacity: captureRingCapacity())

        // Publish both rings atomically under ringLock so a concurrent FFI
        // export (Dart poll/write isolate) snapshots either the whole old or
        // the whole new pair — never a half-swapped or freed ring. The engine
        // is stopped across a reset before we reach here, so the realtime
        // render/sink blocks are not reading the references during the swap and
        // stay lock-free by design.
        ringLock.lock()
        buffer = newOutputRing
        inputRing = newInputRing
        ringLock.unlock()

        inputConverter.outputVolume = 1.0

        try engine.start()
        // The tap only starts once the engine renders, so its ring never fills
        // (and adds latency) while no source node is draining it.
        if #available(macOS 14.2, *), let tap = systemAudioTap as? SystemAudioTap {
            do {
                try tap.start()
            } catch {
                engine.stop()
                throw error
            }
        }
        _isRunning = true
    }

    /// Strong snapshot of the input ring taken under `ringLock`, so the FFI
    /// export retains the instance before the lock is released and a
    /// `startInternal` swap cannot free it mid-use.
    func snapshotInputRing() -> AudioInputRing {
        ringLock.lock()
        defer { ringLock.unlock() }
        return inputRing
    }

    /// Strong snapshot of the output ring taken under `ringLock`; see
    /// `snapshotInputRing()`.
    func snapshotOutputRing() -> AudioOutputRing {
        ringLock.lock()
        defer { ringLock.unlock() }
        return buffer
    }

    /// Builds the capture graph for `_inputSource`:
    ///
    ///     inputNode ──┐
    ///                 ├─▶ inputConverter (mixer) ─▶ sinkNode ─▶ inputRing
    ///     tapSource ──┘
    ///
    /// The microphone leg is only touched when the source includes it —
    /// `engine.inputNode` instantiates the input unit, and a system-audio-only
    /// session must not require microphone access. The processing rate follows
    /// the microphone when present (the tap is resampled by the mixer), else
    /// the tap's own rate.
    public func setupPipelineIfNeeded() throws {
        if _isPipelineSetup { return }

        let output = engine.mainMixerNode
        inputConverter.outputVolume = 1.0
        engine.attach(inputConverter)
        engine.attach(sinkNode)

        var captureRate: Double?
        if _inputSource.usesMicrophone {
            let input = engine.inputNode
            let inputFormat = input.inputFormat(forBus: 0)
            engine.connect(
                input, to: inputConverter,
                fromBus: 0, toBus: inputConverter.nextAvailableInputBus,
                format: inputFormat)
            captureRate = inputFormat.sampleRate
        }
        if _inputSource.usesSystemAudio {
            if #available(macOS 14.2, *) {
                let tap = try SystemAudioTap(ringCapacity: captureRingCapacity())
                let node = createTapSourceNode(tap: tap)
                engine.attach(node)
                engine.connect(
                    node, to: inputConverter,
                    fromBus: 0, toBus: inputConverter.nextAvailableInputBus,
                    format: node.outputFormat(forBus: 0))
                systemAudioTap = tap
                tapSourceNode = node
                captureRate = captureRate ?? tap.sampleRate
            }
        }
        _sampleRate = captureRate ?? _Constants.preferedSampleRate

        let sourceNode = createSourceNode()
        let processingformat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: _sampleRate, channels: 1,
            interleaved: false)
        engine.attach(sourceNode)
        engine.connect(inputConverter, to: sinkNode, format: processingformat)
        engine.connect(sourceNode, to: output, format: nil)
        self.sourceNode = sourceNode
        _isPipelineSetup = true
    }

    /// Renders the tap's mono Float32 ring into the mixer at the tap's sample
    /// rate. A shortfall is zero-filled: the HAL IO proc and the engine render
    /// thread run on the same output-device clock, so underruns only happen at
    /// start-up or across a device change.
    @available(macOS 14.2, *)
    private func createTapSourceNode(tap: SystemAudioTap) -> AVAudioSourceNode {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: tap.sampleRate, channels: 1,
            interleaved: false)!
        let ring = tap.ring
        return AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let first = ablPointer.first,
                let data = first.mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            let frames = Int(frameCount)
            let read = ring.read(into: data, maxCount: frames)
            if read < frames {
                (data + read).initialize(repeating: 0, count: frames - read)
            }
            return noErr
        }
    }

    public func detachPipeline() {
        engine.detach(inputConverter)
        engine.detach(sinkNode)
        if let sourceNode = sourceNode {
            engine.detach(sourceNode)
        }
        if let tapSourceNode = tapSourceNode {
            engine.detach(tapSourceNode)
            self.tapSourceNode = nil
        }
        if #available(macOS 14.2, *), let tap = systemAudioTap as? SystemAudioTap {
            tap.stop()
        }
        systemAudioTap = nil
        // A fresh mixer: detaching does not reset its consumed input busses,
        // so re-connecting the same instance would land on ever-higher busses.
        inputConverter = AVAudioMixerNode()
        _isPipelineSetup = false
    }

    @objc func handleConfigChange(notification _: NSNotification) {
        resetAudio()
    }

    public func resetAudio() {
        if _isRunning && !_resetting {
            _resetting = true
            engine.stop()
            detachPipeline()
            DispatchQueue.main.async {
                try? self.startInternal()
                self._resetting = false
            }
        }
    }

    public func getFormat() -> [String: Any] {
        let inputDesc: [String: Any] = [
            _AudioFormat.dataType: AudioDataTypes.double.rawValue,
            _AudioFormat.channels: 1,
            _AudioFormat.sampleRate: _sampleRate,
        ]

        let outputDesc: [String: Any] = [
            _AudioFormat.dataType: AudioDataTypes.double.rawValue,
            _AudioFormat.channels: 1,
            _AudioFormat.sampleRate: _Constants.outputContractSampleRate,
            _AudioFormat.deviceSampleRate: engine.outputNode.outputFormat(forBus: 0).sampleRate,
        ]

        return [_AudioFormat.input: inputDesc, _AudioFormat.output: outputDesc]
    }
}

// AudioOutputRing / AudioInputRing live in the shared sources
// ios/audio_io/Sources/audio_io/AudioOutputRing.swift and AudioInputRing.swift
// (symlinked into macos/audio_io/Sources/audio_io) so the iOS and macOS copies
// cannot drift.

// MARK: - FFI data plane (#27)
//
// C-callable exports resolved by the Dart side via `DynamicLibrary.process()`
// (the same mechanism `AudioIoBindings` already uses on Apple platforms). Only
// the data plane crosses FFI; engine lifecycle stays on the method channel.
// These reach the live plugin through `AudioIoPlugin.shared`, so they are safe
// to call from any isolate — the ring locks are the only synchronization the
// audio path needs.

/// Number of captured Float32 samples currently queued for reading.
@_cdecl("audio_io_apple_input_available")
public func audio_io_apple_input_available() -> Int32 {
    guard let plugin = AudioIoPlugin.shared else { return 0 }
    return Int32(plugin.snapshotInputRing().availableToRead)
}

/// Drains up to [frames] captured Float32 samples into [buffer]; returns the
/// number actually read (0 when empty).
@_cdecl("audio_io_apple_input_read")
public func audio_io_apple_input_read(
    _ buffer: UnsafeMutablePointer<Float>, _ frames: Int32
) -> Int32 {
    guard let plugin = AudioIoPlugin.shared, frames > 0 else { return 0 }
    return Int32(plugin.snapshotInputRing().read(into: buffer, maxCount: Int(frames)))
}

/// Enqueues [frames] Float64 output samples into the playback ring; returns the
/// number accepted (the newest excess is dropped when the ring is full).
@_cdecl("audio_io_apple_output_write")
public func audio_io_apple_output_write(
    _ buffer: UnsafeMutablePointer<Double>, _ frames: Int32
) -> Int32 {
    guard let plugin = AudioIoPlugin.shared, frames > 0 else { return 0 }
    let samples = UnsafeBufferPointer(start: buffer, count: Int(frames))
    return Int32(plugin.snapshotOutputRing().write(samples))
}

/// Discards output samples queued but not yet rendered (barge-in).
@_cdecl("audio_io_apple_output_clear")
public func audio_io_apple_output_clear() {
    AudioIoPlugin.shared?.snapshotOutputRing().clear()
}

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
    case getFrameDuration
    case requestFormat
    case getFormat
}

enum AudioIoError {
    static let permissionDeniedCode = "MICROPHONE_PERMISSION_DENIED"
    static let permissionDeniedMessage = "Microphone permission not granted. This plugin requires microphone access to function. Please request microphone permission using a package like permission_handler before calling start()."
    static let engineStartCode = "ENGINE_START_ERROR"
    static let engineStartMessage = "Failed to start audio engine"
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

public class AudioIoPlugin: NSObject, FlutterPlugin {
    /// Set once in `register(with:)`. The `@_cdecl` FFI data-plane exports
    /// (see the free functions at the bottom of this file) resolve the live
    /// plugin instance through this singleton — the Dart side reaches the
    /// rings by process symbol via `DynamicLibrary.process()`, not through the
    /// registrar it never sees.
    static fileprivate(set) weak var shared: AudioIoPlugin?

    let engine = AVAudioEngine()
    var inputConverter = AVAudioMixerNode()
    var _frameDuration = _Constants.defaultFrameDuration
    var _sampleRate = _Constants.preferedSampleRate
    var buffer = AudioOutputRing(minimumCapacity: 2048)
    var inputRing = AudioInputRing(minimumCapacity: 2048)
    let maxFrameJitter = _Constants.defaultMaxFrameJitter
    let queue = DispatchQueue(label: _Constants.processingQueueName)
    var _isRunning = false
    var _isPipelineSetup = false
    var _resetting = false

    private var sourceNode: AVAudioSourceNode?

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
            start(result: result)
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
    }

    public func start(result: @escaping FlutterResult) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            result(FlutterError(
                code: AudioIoError.permissionDeniedCode,
                message: AudioIoError.permissionDeniedMessage,
                details: nil))
            return
        case .notDetermined:
            result(FlutterError(
                code: AudioIoError.permissionDeniedCode,
                message: AudioIoError.permissionDeniedMessage,
                details: nil))
            return
        case .authorized:
            break
        @unknown default:
            break
        }

        do {
            try startInternal()
            result(nil)
        } catch let error as NSError {
            result(FlutterError(
                code: error.domain,
                message: error.localizedDescription,
                details: nil))
        }
    }

    private func startInternal() throws {
        buffer = AudioOutputRing(
                minimumCapacity: max(
                    _Constants.ringBufferSize,
                    Int(_frameDuration * _Constants.outputContractSampleRate
                        * maxFrameJitter)))

        try setupPipelineIfNeeded()

        // Sized to the same jitter budget as the output ring, at the capture
        // rate the pipeline negotiated in setupPipelineIfNeeded().
        inputRing = AudioInputRing(
            minimumCapacity: max(
                _Constants.ringBufferSize,
                Int(_frameDuration * _sampleRate * maxFrameJitter)))

        inputConverter.outputVolume = 1.0

        try engine.start()
        _isRunning = true
    }

    public func setupPipelineIfNeeded() throws {
        if !_isPipelineSetup {
            let input = engine.inputNode
            let output = engine.mainMixerNode
            let inputFormat = input.inputFormat(forBus: 0)
            _sampleRate = inputFormat.sampleRate
            inputConverter.outputVolume = 1.0

            let sourceNode = createSourceNode()
            let processingformat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: _sampleRate, channels: 1,
                interleaved: false)
            engine.attach(inputConverter)
            engine.attach(sinkNode)
            engine.attach(sourceNode)
            engine.connect(input, to: inputConverter, format: inputFormat)
            engine.connect(inputConverter, to: sinkNode, format: processingformat)
            engine.connect(sourceNode, to: output, format: nil)
            self.sourceNode = sourceNode
            _isPipelineSetup = true
        }
    }

    public func detachPipeline() {
        engine.detach(inputConverter)
        engine.detach(sinkNode)
        if let sourceNode = sourceNode {
            engine.detach(sourceNode)
        }
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
    return Int32(plugin.inputRing.availableToRead)
}

/// Drains up to [frames] captured Float32 samples into [buffer]; returns the
/// number actually read (0 when empty).
@_cdecl("audio_io_apple_input_read")
public func audio_io_apple_input_read(
    _ buffer: UnsafeMutablePointer<Float>, _ frames: Int32
) -> Int32 {
    guard let plugin = AudioIoPlugin.shared, frames > 0 else { return 0 }
    return Int32(plugin.inputRing.read(into: buffer, maxCount: Int(frames)))
}

/// Enqueues [frames] Float64 output samples into the playback ring; returns the
/// number accepted (the newest excess is dropped when the ring is full).
@_cdecl("audio_io_apple_output_write")
public func audio_io_apple_output_write(
    _ buffer: UnsafeMutablePointer<Double>, _ frames: Int32
) -> Int32 {
    guard let plugin = AudioIoPlugin.shared, frames > 0 else { return 0 }
    let samples = UnsafeBufferPointer(start: buffer, count: Int(frames))
    return Int32(plugin.buffer.write(samples))
}

/// Discards output samples queued but not yet rendered (barge-in).
@_cdecl("audio_io_apple_output_clear")
public func audio_io_apple_output_clear() {
    AudioIoPlugin.shared?.buffer.clear()
}

import AVFoundation
import FlutterMacOS

extension Data {
    init<T>(fromArray values: [T]) {
        self = values.withUnsafeBytes { Data($0) }
    }

    func toArray<T>(type _: T.Type) -> [T] where T: ExpressibleByIntegerLiteral {
        var array = [T](repeating: 0, count: count / MemoryLayout<T>.stride)
        _ = array.withUnsafeMutableBytes { copyBytes(to: $0) }
        return array
    }
}

enum _Constants {
    static let preferedSampleRate = 48000.0
    /// Clients always push mono Float64 at this rate; the source node is
    /// pinned to it and AVAudioEngine converts to the hardware rate, so
    /// Bluetooth (44.1 kHz A2DP, 16-24 kHz HFP input) and other devices
    /// play at correct speed while the engine keeps consuming 48 k/s.
    static let outputContractSampleRate = 48000.0
    static let workspaceSamples = 100_000
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
    case inputChannelName = "com.wearemobilefirst.audio_io.inputAudio"
    case outputChannelName = "com.wearemobilefirst.audio_io.outputAudio"
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

/// Guarded by os_unfair_lock (priority donating, no allocation) because
/// acquire() runs on the realtime render thread; a serial DispatchQueue
/// there can block the audio callback behind a descheduled worker.
class DataBufferPool {
    private var pool: [Data] = []
    private let bufferSize: Int
    private let poolSize: Int
    private let lockPtr: UnsafeMutablePointer<os_unfair_lock>

    init(bufferSize: Int, poolSize: Int = 8) {
        self.bufferSize = bufferSize
        self.poolSize = poolSize
        lockPtr = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lockPtr.initialize(to: os_unfair_lock())
        for _ in 0..<poolSize {
            pool.append(Data(count: bufferSize))
        }
    }

    deinit {
        lockPtr.deinitialize(count: 1)
        lockPtr.deallocate()
    }

    func acquire() -> Data {
        os_unfair_lock_lock(lockPtr)
        defer { os_unfair_lock_unlock(lockPtr) }
        if pool.isEmpty {
            return Data(count: bufferSize)
        }
        return pool.removeLast()
    }

    func release(_ data: Data) {
        os_unfair_lock_lock(lockPtr)
        defer { os_unfair_lock_unlock(lockPtr) }
        if pool.count < poolSize {
            pool.append(data)
        }
    }
}

public class AudioIoPlugin: NSObject, FlutterPlugin {
    let engine = AVAudioEngine()
    var inputConverter = AVAudioMixerNode()
    var _binaryMessenger: FlutterBinaryMessenger?
    var _frameDuration = _Constants.defaultFrameDuration
    var _sampleRate = _Constants.preferedSampleRate
    var buffer = AudioOutputRing(minimumCapacity: 2048)
    let maxFrameJitter = _Constants.defaultMaxFrameJitter
    let queue = DispatchQueue(label: _Constants.processingQueueName)
    var _isRunning = false
    var _isPipelineSetup = false
    var _resetting = false
    var bufferPool: DataBufferPool?

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

    private lazy var sinkNode = AVAudioSinkNode { [weak self] _, frames, audioBufferList -> OSStatus in
        guard let self = self else { return noErr }
        let sampleCount = Int(frames)
        guard let ptr = audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else {
            return noErr
        }

        let byteCount = sampleCount * MemoryLayout<Double>.stride
        var doubleData = self.bufferPool?.acquire() ?? Data(count: byteCount)

        if doubleData.count != byteCount {
            doubleData = Data(count: byteCount)
        }

        doubleData.withUnsafeMutableBytes { doublePtr in
            let doubles = doublePtr.bindMemory(to: Double.self)
            for i in 0..<sampleCount {
                doubles[i] = Double(ptr[i])
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self._binaryMessenger?.send(
                onChannel: Channels.inputChannelName.rawValue, message: doubleData,
                binaryReply: { [weak self] _ in
                    self?.bufferPool?.release(doubleData)
                })
        }
        return noErr
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: Channels.methodChannelName.rawValue, binaryMessenger: registrar.messenger)
        let instance = AudioIoPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        instance._binaryMessenger = registrar.messenger
        instance._binaryMessenger?.setMessageHandlerOnChannel(
            Channels.outputChannelName.rawValue,
            binaryMessageHandler: { [weak instance] data, _ in
                guard let data = data, let instance = instance else {
                    return
                }
                autoreleasepool {
                    data.withUnsafeBytes { rawPtr in
                        instance.buffer.write(rawPtr.bindMemory(to: Double.self))
                    }
                }
            })

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

        let expectedFrameSize = Int(_frameDuration * _sampleRate)
        let bufferSize = expectedFrameSize * MemoryLayout<Double>.stride
        bufferPool = DataBufferPool(bufferSize: bufferSize, poolSize: 8)

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

// AudioOutputRing lives in the shared source ios/Classes/AudioOutputRing.swift
// (symlinked into macos/Classes) so the iOS and macOS copies cannot drift.

extension Double {
    public static var random: Double {
        return Double(arc4random()) / 0xFFFF_FFFF
    }

    public static func random(min: Double, max: Double) -> Double {
        return Double.random * (max - min) + min
    }
}

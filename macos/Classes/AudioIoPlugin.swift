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

private enum _Constants {
    static let defaultSampleRate = 48000.0
    static let workspaceSamples = 100_000
    static let defaultFrameDuration = 0.003
    static let defaultMaxFrameJitter = 4.0
    static let processingQueueName = "SwiftAudioIoPluginQueue"
    static let formatFloat64 = "float64"
    static let formatPcm16 = "pcm16"
    static let pcm16ScaleFactor: Float = 32767.0
}

enum Methods: String {
    case start
    case stop
    case requestFrameDuration
    case getFrameDuration
    case requestFormat
    case getFormat
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
    case int16
}

enum _AudioFormat {
    static let sampleRate = "sampleRate"
    static let dataType = "type"
    static let channels = "channels"
    static let input = "input"
    static let output = "output"
    static let format = "format"
}

public class AudioIoPlugin: NSObject, FlutterPlugin {
    let engine = AVAudioEngine()
    var _binaryMessenger: FlutterBinaryMessenger?
    var _frameDuration = _Constants.defaultFrameDuration
    var _sampleRate = _Constants.defaultSampleRate
    var _requestedSampleRate = _Constants.defaultSampleRate
    var _requestedFormat = _Constants.formatFloat64
    var buffer = RingBuffer<Float>(count: 0)
    let maxFrameJitter = _Constants.defaultMaxFrameJitter
    let queue = DispatchQueue(label: _Constants.processingQueueName)
    var _isRunning = false
    var _isPipelineSetup = false
    var _resetting = false

    private var sourceNode: AVAudioSourceNode?
    private var inputAudioConverter: AVAudioConverter?

    private func createSourceNode() -> AVAudioSourceNode {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: _sampleRate, channels: 1, interleaved: false)!
        return AVAudioSourceNode(format: format, renderBlock: { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            self.queue.sync {
                for buffer in ablPointer {
                    let buf: UnsafeMutableBufferPointer<Float> = UnsafeMutableBufferPointer(buffer)
                    var i = 0
                    while i < frameCount {
                        buf[i] = self.buffer.read() ?? 0
                        i += 1
                    }
                }
            }
            return noErr
        })
    }

    // Captured mic audio arrives at the hardware rate via the input tap and is
    // resampled down to the requested rate by `inputAudioConverter` before it is
    // converted to PCM16/Float64 and pushed to Flutter. macOS has no
    // AVAudioSession to negotiate the device rate, so the conversion must happen
    // explicitly here — otherwise the mic always streams at 48 kHz.
    private func handleCapturedBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        guard let converter = inputAudioConverter else { return }
        let outputFormat = converter.outputFormat

        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 64
        guard capacity > 0,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, inStatus in
            if consumed {
                inStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error || error != nil {
            print("Input conversion error \(String(describing: error))")
            return
        }

        let sampleCount = Int(outputBuffer.frameLength)
        guard sampleCount > 0, let channel = outputBuffer.floatChannelData else { return }
        let samples = channel[0]

        let data: Data
        if _requestedFormat == _Constants.formatPcm16 {
            var int16Samples = [Int16](repeating: 0, count: sampleCount)
            var i = 0
            while i < sampleCount {
                let clamped = min(max(samples[i], -1.0), 1.0)
                int16Samples[i] = Int16(clamped * _Constants.pcm16ScaleFactor)
                i += 1
            }
            data = Data(fromArray: int16Samples)
        } else {
            var doubleSamples = [Double](repeating: 0.0, count: sampleCount)
            var i = 0
            while i < sampleCount {
                doubleSamples[i] = Double(samples[i])
                i += 1
            }
            data = Data(fromArray: doubleSamples)
        }

        _binaryMessenger?.send(onChannel: Channels.inputChannelName.rawValue, message: data)
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: Channels.methodChannelName.rawValue, binaryMessenger: registrar.messenger)
        let instance = AudioIoPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        instance._binaryMessenger = registrar.messenger
        instance._binaryMessenger?.setMessageHandlerOnChannel(Channels.outputChannelName.rawValue, binaryMessageHandler: { data, _ in
            guard let data = data else {
                return
            }
            instance.queue.async {
                if instance._requestedFormat == _Constants.formatPcm16 {
                    let int16s: [Int16] = data.toArray(type: Int16.self)
                    let floats = int16s.map { Float($0) / _Constants.pcm16ScaleFactor }
                    _ = instance.buffer.writeBlock(floats)
                } else {
                    let doubles: [Double] = data.toArray(type: Double.self)
                    let floats = doubles.map { Float($0) }
                    _ = instance.buffer.writeBlock(floats)
                }
            }
        })

        NotificationCenter.default.addObserver(instance, selector: #selector(handleConfigChange), name: NSNotification.Name.AVAudioEngineConfigurationChange, object: nil)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case Methods.start.rawValue:
            // Plain start() carries no args. Reset to defaults first so a prior
            // startWith(pcm16/non-default rate) doesn't leak its requested format
            // or sample rate into a subsequent default start().
            _requestedSampleRate = _Constants.defaultSampleRate
            _requestedFormat = _Constants.formatFloat64
            if let args = call.arguments as? [String: Any] {
                // Dart sends `sampleRate` (int hz) and `format` (int 0=float64, 1=pcm16),
                // both of which arrive as NSNumber over the method channel — not Double/String.
                // Casting an int-backed NSNumber `as? String` is always nil, so the previous
                // code silently fell back to float64 and PCM16 never activated on Apple platforms.
                if let sampleRate = args["sampleRate"] as? NSNumber {
                    _requestedSampleRate = sampleRate.doubleValue
                }
                if let format = args["format"] as? NSNumber {
                    _requestedFormat = format.intValue == 1 ? _Constants.formatPcm16 : _Constants.formatFloat64
                } else if let format = args["format"] as? String {
                    _requestedFormat = format
                }
            }
            start()
            result(nil)
        case Methods.stop.rawValue:
            stop()
            result(nil)
        case Methods.requestFrameDuration.rawValue:
            if let requested = call.arguments as? Double {
                _frameDuration = requested
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
        print("Stop Audio Engine")
        engine.stop()
        _isRunning = false
    }

    public func start() {
        print("Start Audio Engine")
        _sampleRate = _requestedSampleRate
        // Output is fed from the network (Gemini) in bursts, so the playback ring
        // buffer must hold seconds — not milliseconds — of audio to avoid
        // underruns. Sized at the requested rate because the sourceNode renders
        // at the requested rate and the mixer resamples up to the hardware rate.
        let bufferSize = max(Int(_sampleRate * 10.0), 131072)
        buffer = RingBuffer<Float>(count: bufferSize)

        do {
            try setupPipelineIfNeeded()
        } catch {
            print("Audio pipeline error \(error)")
            return
        }

        do {
            try engine.start()
            _isRunning = true
        } catch {
            print("Audio start error")
        }
    }

    public func setupPipelineIfNeeded() throws {
        if !_isPipelineSetup {
            print("setupPipeline")
            let input = engine.inputNode
            let output = engine.mainMixerNode

            // Keep the engine at the hardware rate and convert at the boundaries
            // (the pattern Apple recommends): _sampleRate stays at the *requested*
            // rate so Flutter receives the rate it asked for. Previously
            // `_sampleRate` was overwritten with `inputFormat.sampleRate`, which
            // forced the whole pipeline to 48 kHz — playback ran ~3x fast and the
            // mic streamed at 48 kHz while Gemini expects 16 kHz.
            let hardwareInputFormat = input.outputFormat(forBus: 0)
            guard hardwareInputFormat.sampleRate > 0 else {
                throw NSError(domain: Channels.methodChannelName.rawValue, code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Input device unavailable (sampleRate 0). Check microphone permission/entitlement."])
            }
            let processingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: _sampleRate,
                                                 channels: 1,
                                                 interleaved: false)!

            // Output: Dart writes requested-rate float into the ring buffer; the
            // sourceNode renders at the requested rate and the main mixer
            // resamples up to the hardware output rate.
            let sourceNode = createSourceNode()
            engine.attach(sourceNode)
            engine.connect(sourceNode, to: output, format: processingFormat)
            self.sourceNode = sourceNode

            // Input: tap the mic at the hardware rate and resample down to the
            // requested rate with a persistent converter (state carries across
            // callbacks, so there are no resampling discontinuities).
            guard let converter = AVAudioConverter(from: hardwareInputFormat, to: processingFormat) else {
                throw NSError(domain: Channels.methodChannelName.rawValue, code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "Could not create input converter \(hardwareInputFormat) -> \(processingFormat)"])
            }
            inputAudioConverter = converter
            input.installTap(onBus: 0, bufferSize: 4096, format: hardwareInputFormat) { [weak self] buffer, _ in
                self?.handleCapturedBuffer(buffer)
            }

            _isPipelineSetup = true
            print("setupPipeline complete (hwIn=\(hardwareInputFormat.sampleRate) requested=\(_sampleRate))")
        }
    }

    public func detachPipeline() {
        print("detachPipeline")
        engine.inputNode.removeTap(onBus: 0)
        if let sourceNode = sourceNode {
            engine.detach(sourceNode)
        }
        inputAudioConverter = nil
        _isPipelineSetup = false
    }

    @objc func handleConfigChange(notification _: NSNotification) {
        print("handleConfigChange:")
        resetAudio()
    }

    public func resetAudio() {
        if _isRunning && !_resetting {
            _resetting = true
            print("Resetting Audio Engine")
            engine.stop()
            detachPipeline()
            DispatchQueue.main.async {
                self.start()
                self._resetting = false
            }
        }
    }

    public func getFormat() -> [String: Any] {
        let dataType = _requestedFormat == _Constants.formatPcm16
            ? AudioDataTypes.int16.rawValue
            : AudioDataTypes.double.rawValue

        let inputDesc: [String: Any] = [_AudioFormat.dataType: dataType,
                                        _AudioFormat.channels: 1,
                                        _AudioFormat.sampleRate: _sampleRate,
                                        _AudioFormat.format: _requestedFormat]

        let outputDesc: [String: Any] = [_AudioFormat.dataType: dataType,
                                         _AudioFormat.channels: 1,
                                         _AudioFormat.sampleRate: _sampleRate,
                                         _AudioFormat.format: _requestedFormat]

        return [_AudioFormat.input: inputDesc, _AudioFormat.output: outputDesc]
    }
}

public struct RingBuffer<T> {
    fileprivate var array: [T?]
    fileprivate var readIndex = 0
    fileprivate var writeIndex = 0

    public init(count: Int) {
        array = [T?](repeating: nil, count: count)
    }

    public mutating func write(_ element: T) -> Bool {
        if !isFull {
            array[writeIndex % array.count] = element
            writeIndex += 1
            return true
        } else {
            return false
        }
    }

    public mutating func writeBlock(_ block: [T]) -> Bool {
        let count = block.count
        guard availableSpaceForWriting >= count else {
            return false
        }

        let writeStartIndex = writeIndex % array.count

        if writeStartIndex + count <= array.count {
            for i in 0 ..< count {
                array[writeStartIndex + i] = block[i]
            }
        } else {
            let firstPartCount = array.count - writeStartIndex
            for i in 0 ..< firstPartCount {
                array[writeStartIndex + i] = block[i]
            }
            for i in 0 ..< count - firstPartCount {
                array[i] = block[firstPartCount + i]
            }
        }

        writeIndex += count
        return true
    }

    public mutating func read() -> T? {
        if !isEmpty {
            let element = array[readIndex % array.count]
            readIndex += 1
            return element
        } else {
            return nil
        }
    }

    public mutating func readBlock(count: Int) -> [T?]? {
        if availableSpaceForReading >= count {
            var result = [T?](repeating: nil, count: count)
            for i in 0 ..< count {
                result[i] = array[(readIndex + i) % array.count]
            }
            readIndex += count
            return result
        }
        return nil
    }

    public mutating func clear() {
        readIndex = 0
        writeIndex = 0
    }

    fileprivate var availableSpaceForReading: Int {
        return writeIndex - readIndex
    }

    public var isEmpty: Bool {
        return availableSpaceForReading == 0
    }

    fileprivate var availableSpaceForWriting: Int {
        return array.count - availableSpaceForReading
    }

    public var isFull: Bool {
        return availableSpaceForWriting == 0
    }
}

public extension Double {
    static var random: Double {
        return Double(arc4random()) / 0xFFFF_FFFF
    }

    static func random(min: Double, max: Double) -> Double {
        return Double.random * (max - min) + min
    }
}

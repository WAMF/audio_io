import AVFoundation
import Flutter

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

public class SwiftAudioIoPlugin: NSObject, FlutterPlugin {
    let engine = AVAudioEngine()
    var inputConverter = AVAudioMixerNode()
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

    private lazy var sinkNode = AVAudioSinkNode { _, frames, audioBufferList ->
        OSStatus in
        let sampleCount = Int(frames)
        let ptr = audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self)
        let unsafePtr = UnsafeBufferPointer(start: ptr, count: sampleCount)

        let data: Data
        if self._requestedFormat == _Constants.formatPcm16 {
            var int16Samples = [Int16](repeating: 0, count: sampleCount)
            var i = 0
            while i < sampleCount {
                let clamped = min(max(unsafePtr[i], -1.0), 1.0)
                int16Samples[i] = Int16(clamped * _Constants.pcm16ScaleFactor)
                i += 1
            }
            data = Data(fromArray: int16Samples)
        } else {
            var doubleSamples = [Double](repeating: 0.0, count: sampleCount)
            var i = 0
            while i < sampleCount {
                doubleSamples[i] = Double(unsafePtr[i])
                i += 1
            }
            data = Data(fromArray: doubleSamples)
        }

        self._binaryMessenger?.send(onChannel: Channels.inputChannelName.rawValue, message: data)
        return noErr
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: Channels.methodChannelName.rawValue, binaryMessenger: registrar.messenger())
        let instance = SwiftAudioIoPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        instance._binaryMessenger = registrar.messenger()
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
        NotificationCenter.default.addObserver(instance, selector: #selector(handleRouteChange), name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(instance, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case Methods.start.rawValue:
            if let args = call.arguments as? [String: Any] {
                _requestedSampleRate = args["sampleRate"] as? Double ?? _Constants.defaultSampleRate
                _requestedFormat = args["format"] as? String ?? _Constants.formatFloat64
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
        buffer = RingBuffer<Float>(count: Int(_frameDuration * _sampleRate * maxFrameJitter))

        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.allowBluetoothA2DP, .defaultToSpeaker])
            try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(_frameDuration)
            try AVAudioSession.sharedInstance().setPreferredSampleRate(_requestedSampleRate)
        } catch {
            print("Session config Error")
            return
        }

        do {
            try setupPipelineIfNeeded()
        } catch {
            print("Audio pipeline error \(error)")
            return
        }

        inputConverter.outputVolume = 1.0

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
            let inputFormat = input.inputFormat(forBus: 0)
            _sampleRate = inputFormat.sampleRate
            inputConverter.outputVolume = 1.0
            let sourceNode = createSourceNode()
            let processingformat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: _sampleRate, channels: 1, interleaved: false)
            engine.attach(inputConverter)
            engine.attach(sinkNode)
            engine.attach(sourceNode)
            engine.connect(input, to: inputConverter, format: inputFormat)
            engine.connect(inputConverter, to: sinkNode, format: processingformat)
            engine.connect(sourceNode, to: output, format: nil)
            self.sourceNode = sourceNode
            _isPipelineSetup = true
            print("setupPipeline complete")
        }
    }

    public func detachPipeline() {
        print("detachPipeline")
        engine.detach(inputConverter)
        engine.detach(sinkNode)
        if let sourceNode = sourceNode {
            engine.detach(sourceNode)
        }
        _isPipelineSetup = false
    }

    @objc func handleConfigChange(notification _: NSNotification) {
        print("handleConfigChange:")
        resetAudio()
    }

    @objc func handleInterruption(notification: NSNotification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue),
              _isRunning
        else {
            return
        }
        switch type {
        case .began:
            print("handleInterruption: began")
        case .ended:
            print("handleInterruption: ended")
        default: ()
        }
    }

    @objc func handleRouteChange(notification: NSNotification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else {
            return
        }
        switch reason {
        case .newDeviceAvailable:
            print("newDeviceAvailable:")
        case .oldDeviceUnavailable:
            print("oldDeviceAvailable:")
        case .routeConfigurationChange:
            print("routeConfigurationChange:")
        case .categoryChange:
            print("routeConfigurationChange:")
        default: ()
            print("handleRouteChange:")
            print(reasonValue)
        }
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

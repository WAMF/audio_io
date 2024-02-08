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

enum _Constants {
    static let preferedSampleRate = 48000.0
    static let workspaceSamples = 100_000
    static let defaultFrameDuration = 0.003 // (3ms)
    static let defaultMaxFrameJitter = 4.0
    static let processingQueueName = "SwiftAudioIoPluginQueue"
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
}

enum _AudioFormat {
    static let sampleRate = "sampleRate"
    static let dataType = "type"
    static let channels = "channels"
    static let input = "input"
    static let output = "output"
}

public class SwiftAudioIoPlugin: NSObject, FlutterPlugin {
    let engine = AVAudioEngine()
    var inputConverter = AVAudioMixerNode()
    var _binaryMessenger: FlutterBinaryMessenger?
    var _frameDuration = _Constants.defaultFrameDuration
    var _sampleRate = _Constants.preferedSampleRate
    var buffer = RingBuffer<Double>(count: 0)
    let maxFrameJitter = _Constants.defaultMaxFrameJitter
    let queue = DispatchQueue(label: _Constants.processingQueueName)
    var _isRunning = false
    var _isPipelineSetup = false
    var _resetting = false

    private var sourceNode: AVAudioSourceNode?

    private func createSourceNode() -> AVAudioSourceNode {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat64, sampleRate: _sampleRate, channels: 1, interleaved: false)!
        return AVAudioSourceNode(format: format, renderBlock: { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            self.queue.sync {
                for buffer in ablPointer {
                    let buf: UnsafeMutableBufferPointer<Double> = UnsafeMutableBufferPointer(buffer)
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
        var doubleSamples = [Double](repeating: 0.0, count: sampleCount)
        let ptr = audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self)
        let unsafePtr = UnsafeBufferPointer(start: ptr, count: sampleCount)
        var i = 0
        while i < sampleCount {
            doubleSamples[i] = Double(unsafePtr[i])
            i += 1
        }
        let data = Data(fromArray: doubleSamples)
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
                let doubles: [Double] = data.toArray(type: Double.self)
                _ = instance.buffer.writeBlock(doubles)
            }
        })

        NotificationCenter.default.addObserver(instance, selector: #selector(handleConfigChange), name: NSNotification.Name.AVAudioEngineConfigurationChange, object: nil)
        NotificationCenter.default.addObserver(instance, selector: #selector(handleRouteChange), name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(instance, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case Methods.start.rawValue:
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
        buffer = RingBuffer<Double>(count: Int(_frameDuration * _sampleRate * maxFrameJitter))
        // Setup AVAudioSession
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.allowBluetoothA2DP, .defaultToSpeaker])
            try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(_frameDuration)
            try AVAudioSession.sharedInstance().setPreferredSampleRate(_sampleRate)
        } catch {
            print("Session config Error")
            return
        }

        // Connect nodes
        do {
            try setupPipelineIfNeeded()
        } catch {
            print("Audio pipeline error \(error)")
            return
        }

        inputConverter.outputVolume = 1.0

        // Start engine
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
            // Setup engine and node instances
            let input = engine.inputNode
            let output = engine.mainMixerNode
            let inputFormat = input.inputFormat(forBus: 0)
            _sampleRate = inputFormat.sampleRate
            inputConverter.outputVolume = 1.0
            // Connect nodes
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
        let inputDesc: [String: Any] = [_AudioFormat.dataType: AudioDataTypes.double.rawValue,
                                        _AudioFormat.channels: 1,
                                        _AudioFormat.sampleRate: _sampleRate]

        let outputDesc: [String: Any] = [_AudioFormat.dataType: AudioDataTypes.double.rawValue,
                                         _AudioFormat.channels: 1,
                                         _AudioFormat.sampleRate: _sampleRate]

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

    public mutating func writeBlock(_ block: [T?]) -> Bool {
        let count = block.count
        guard availableSpaceForWriting >= count else {
            return false
        }

        let writeStartIndex = writeIndex % array.count

        if writeStartIndex + count <= array.count {
            // Block fits entirely without wrapping around
            array.replaceSubrange(writeStartIndex ..< writeStartIndex + count, with: block)
        } else {
            // Block wraps around the end of the buffer
            let firstPartCount = array.count - writeStartIndex
            array.replaceSubrange(writeStartIndex ..< writeStartIndex + firstPartCount, with: block[..<firstPartCount])
            array.replaceSubrange(0 ..< count - firstPartCount, with: block[firstPartCount...])
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

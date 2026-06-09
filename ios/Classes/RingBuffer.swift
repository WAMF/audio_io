// RingBuffer.swift
//
// Single shared source of the audio ring buffer, compiled by BOTH the iOS and
// macOS plugin pods. The iOS pod compiles this file directly (it lives under
// ios/Classes); the macOS pod compiles it via the symlink
// macos/Classes/RingBuffer.swift -> ../../ios/Classes/RingBuffer.swift, so
// there is exactly one implementation and it cannot drift between platforms.
//
// Previously the RingBuffer struct (and the small Double helper below) were
// hand-duplicated verbatim in SwiftAudioIoPlugin.swift (iOS) and
// AudioIoPlugin.swift (macOS); the macOS RunnerTests suite is the single XCTest
// gate that exercises this type (see .github/workflows/xctest.yml).

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

    @discardableResult
    public mutating func writeBlock(_ block: [T]) -> Int {
        let count = block.count
        if count == 0 {
            return 0
        }

        // A burst larger than the whole ring can only retain its most recent
        // array.count samples; the earlier ones are counted as discarded.
        let startOffset = count > array.count ? count - array.count : 0
        let writeCount = count - startOffset
        var discarded = startOffset

        // Drop the oldest queued samples to make room instead of refusing the
        // block, so a producer outpacing playback keeps the newest audio rather
        // than silently losing whole incoming chunks.
        let overflow = writeCount - availableSpaceForWriting
        if overflow > 0 {
            readIndex += overflow
            discarded += overflow
        }

        let writeStartIndex = writeIndex % array.count

        if writeStartIndex + writeCount <= array.count {
            for i in 0 ..< writeCount {
                array[writeStartIndex + i] = block[startOffset + i]
            }
        } else {
            let firstPartCount = array.count - writeStartIndex
            for i in 0 ..< firstPartCount {
                array[writeStartIndex + i] = block[startOffset + i]
            }
            for i in 0 ..< writeCount - firstPartCount {
                array[i] = block[startOffset + firstPartCount + i]
            }
        }

        writeIndex += writeCount
        return discarded
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

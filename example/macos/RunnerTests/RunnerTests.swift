import Cocoa
import FlutterMacOS
import XCTest

// Public import is sufficient: AudioOutputRing is a `public final class` and
// every member exercised below (init/write/read/clear) is public, so this
// compiles without the plugin module being built for `@testable`.
import audio_io

class RunnerTests: XCTestCase {

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

}

// MARK: - AudioOutputRing coverage
//
// The Darwin output path (and clearOutput(), PR #7) bottoms out in
// AudioOutputRing: a lock-free SPSC ring that drops the newest samples on
// overflow and zero-fills read shortfalls. The index arithmetic and the
// clear() reset are off-by-one-prone, so these cases lock the invariants.
// AudioOutputRing is a single shared source compiled by both the iOS and
// macOS pods; the macOS RunnerTests target is the one wired into CI
// (see .github/workflows/xctest.yml).
class AudioOutputRingTests: XCTestCase {

  private func write(_ ring: AudioOutputRing, _ samples: [Double]) -> Int {
    return samples.withUnsafeBufferPointer { ring.write($0) }
  }

  private func read(_ ring: AudioOutputRing, _ count: Int) -> [Double] {
    var out = [Double](repeating: .nan, count: count)
    out.withUnsafeMutableBufferPointer { ring.read(into: $0, count: count) }
    return out
  }

  // Round-trip: samples come back in order, and reading past the queued count
  // zero-fills the shortfall rather than returning stale memory.
  func testWriteReadRoundTripAndZeroFill() {
    let ring = AudioOutputRing(minimumCapacity: 2048)
    XCTAssertEqual(write(ring, [1, 2, 3]), 3)

    XCTAssertEqual(read(ring, 5), [1, 2, 3, 0, 0], "shortfall must zero-fill")
  }

  // Overflow drops the newest samples (the ring reports how many it accepted),
  // and the already-queued samples are preserved in order.
  func testWriteDropsNewestOnOverflow() {
    let ring = AudioOutputRing(minimumCapacity: 2048) // capacity == 2048
    let fill = (0..<2048).map(Double.init)
    XCTAssertEqual(write(ring, fill), 2048, "a full ring accepts exactly its capacity")

    XCTAssertEqual(write(ring, [9, 9, 9]), 0, "writes to a full ring are dropped (drop-newest)")

    let out = read(ring, 2048)
    XCTAssertEqual(out.first, 0)
    XCTAssertEqual(out.last, 2047, "the oldest samples survive; the newest overflow is dropped")
  }

  // A partial overflow accepts only what fits and drops the rest.
  func testWriteAcceptsOnlyWhatFits() {
    let ring = AudioOutputRing(minimumCapacity: 2048)
    XCTAssertEqual(write(ring, Array(repeating: 1.0, count: 2046)), 2046) // 2 free

    XCTAssertEqual(write(ring, [7, 8, 9, 10]), 2, "only the 2 free slots are filled")
  }

  // clear() drops queued samples (read zero-fills afterwards) and leaves the
  // indices coherent so a fresh write reads back cleanly with no stale data.
  func testClearEmptiesOutput() {
    let ring = AudioOutputRing(minimumCapacity: 2048)
    XCTAssertEqual(write(ring, [1, 2, 3]), 3)

    ring.clear()

    XCTAssertEqual(read(ring, 3), [0, 0, 0], "clear() drops queued samples; read zero-fills")

    XCTAssertEqual(write(ring, [9, 9]), 2)
    XCTAssertEqual(read(ring, 2), [9, 9], "fresh write after clear reads back cleanly")
  }
}

// MARK: - AudioInputRing coverage
//
// The Darwin capture path (#27) bottoms out in AudioInputRing: the Float32
// SPSC ring the AVAudioSinkNode render block writes into and the Dart FFI poll
// loop drains. It mirrors AudioOutputRing's index arithmetic but differs in
// two ways worth locking: read() returns the count actually read (never
// zero-fills — the consumer wants exactly what is available), and
// availableToRead reports the queue depth the poll loop keys off. Like
// AudioOutputRing this is a single shared source compiled by both pods and run
// via the macOS RunnerTests target in CI (see .github/workflows/xctest.yml).
class AudioInputRingTests: XCTestCase {

  @discardableResult
  private func write(_ ring: AudioInputRing, _ samples: [Float]) -> Int {
    return samples.withUnsafeBufferPointer { ring.write($0) }
  }

  private func read(_ ring: AudioInputRing, _ maxCount: Int) -> [Float] {
    var out = [Float](repeating: .nan, count: maxCount)
    let read = out.withUnsafeMutableBufferPointer {
      ring.read(into: $0.baseAddress!, maxCount: maxCount)
    }
    return Array(out.prefix(read))
  }

  // Round-trip: samples come back in order, and a read for more than is queued
  // returns only what is available (no zero-filled tail, unlike the output ring).
  func testWriteReadRoundTripReturnsOnlyAvailable() {
    let ring = AudioInputRing(minimumCapacity: 2048)
    XCTAssertEqual(write(ring, [1, 2, 3]), 3)
    XCTAssertEqual(ring.availableToRead, 3)

    XCTAssertEqual(read(ring, 5), [1, 2, 3], "read returns only the queued samples")
    XCTAssertEqual(ring.availableToRead, 0)
    XCTAssertEqual(read(ring, 5), [], "an empty ring reads back nothing")
  }

  // Overflow drops the newest samples (the ring reports how many it accepted),
  // and the already-queued samples are preserved in order.
  func testWriteDropsNewestOnOverflow() {
    let ring = AudioInputRing(minimumCapacity: 2048) // capacity == 2048
    let fill = (0..<2048).map(Float.init)
    XCTAssertEqual(write(ring, fill), 2048, "a full ring accepts exactly its capacity")

    XCTAssertEqual(write(ring, [9, 9, 9]), 0, "writes to a full ring are dropped (drop-newest)")

    let out = read(ring, 2048)
    XCTAssertEqual(out.first, 0)
    XCTAssertEqual(out.last, 2047, "the oldest samples survive; the newest overflow is dropped")
  }

  // A partial overflow accepts only what fits and drops the rest.
  func testWriteAcceptsOnlyWhatFits() {
    let ring = AudioInputRing(minimumCapacity: 2048)
    XCTAssertEqual(write(ring, Array(repeating: 1.0, count: 2046)), 2046) // 2 free

    XCTAssertEqual(write(ring, [7, 8, 9, 10]), 2, "only the 2 free slots are filled")
  }

  // clear() drops queued samples and leaves the indices coherent so a fresh
  // write reads back cleanly with no stale data.
  func testClearEmptiesInput() {
    let ring = AudioInputRing(minimumCapacity: 2048)
    XCTAssertEqual(write(ring, [1, 2, 3]), 3)

    ring.clear()

    XCTAssertEqual(ring.availableToRead, 0)
    XCTAssertEqual(read(ring, 3), [], "clear() drops queued samples")

    XCTAssertEqual(write(ring, [9, 9]), 2)
    XCTAssertEqual(read(ring, 2), [9, 9], "fresh write after clear reads back cleanly")
  }
}

// MARK: - SystemAudioTap helpers (#32)
//
// The Core Audio tap itself needs a signed app, a TCC grant, and a live output
// device, none of which CI has. Its pure helpers — the channel downmix that
// runs on the HAL IO thread and the aggregate-device description — are what
// can drift silently, so they are pinned here.
class SystemAudioTapHelperTests: XCTestCase {

  func testInterleavedStereoDownmixAveragesChannels() throws {
    guard #available(macOS 14.2, *) else { throw XCTSkip("Core Audio taps need macOS 14.2") }
    let interleaved: [Float] = [1, 3, -2, 2, 0.5, 0.5]
    var mono = [Float](repeating: .nan, count: 3)
    interleaved.withUnsafeBufferPointer { input in
      mono.withUnsafeMutableBufferPointer { output in
        SystemAudioTap.downmix(
          interleaved: input.baseAddress!, channels: 2, frames: 3,
          into: output.baseAddress!)
      }
    }
    XCTAssertEqual(mono, [2, 0, 0.5])
  }

  func testPlanarDownmixAveragesPlanes() throws {
    guard #available(macOS 14.2, *) else { throw XCTSkip("Core Audio taps need macOS 14.2") }
    let left: [Float] = [1, 1, 1]
    let right: [Float] = [0, -1, 3]
    var mono = [Float](repeating: .nan, count: 3)
    left.withUnsafeBufferPointer { l in
      right.withUnsafeBufferPointer { r in
        mono.withUnsafeMutableBufferPointer { output in
          SystemAudioTap.downmix(
            planes: [l.baseAddress!, r.baseAddress!], frames: 3,
            into: output.baseAddress!)
        }
      }
    }
    XCTAssertEqual(mono, [0.5, 0, 2])
  }

  func testAggregateDescriptionPairsOutputDeviceWithTap() throws {
    guard #available(macOS 14.2, *) else { throw XCTSkip("Core Audio taps need macOS 14.2") }
    let tapUUID = UUID()
    let description = SystemAudioTap.aggregateDescription(
      outputDeviceUID: "BuiltInSpeakerDevice", tapUUID: tapUUID)

    XCTAssertEqual(description[kAudioAggregateDeviceMainSubDeviceKey] as? String, "BuiltInSpeakerDevice")
    XCTAssertEqual(description[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
    XCTAssertEqual(description[kAudioAggregateDeviceTapAutoStartKey] as? Bool, true)

    let subDevices = description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]]
    XCTAssertEqual(subDevices?.count, 1)
    XCTAssertEqual(subDevices?.first?[kAudioSubDeviceUIDKey] as? String, "BuiltInSpeakerDevice")

    let taps = description[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
    XCTAssertEqual(taps?.count, 1)
    XCTAssertEqual(taps?.first?[kAudioSubTapUIDKey] as? String, tapUUID.uuidString)
    XCTAssertEqual(taps?.first?[kAudioSubTapDriftCompensationKey] as? Bool, true)
    XCTAssertNotNil(description[kAudioAggregateDeviceUIDKey] as? String)
  }
}

import Flutter
import UIKit
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
// macOS pods; this suite mirrors the macOS RunnerTests (the CI-wired target).
class AudioOutputRingTests: XCTestCase {

  private func write(_ ring: AudioOutputRing, _ samples: [Double]) -> Int {
    return samples.withUnsafeBufferPointer { ring.write($0) }
  }

  private func read(_ ring: AudioOutputRing, _ count: Int) -> [Double] {
    var out = [Double](repeating: .nan, count: count)
    out.withUnsafeMutableBufferPointer { ring.read(into: $0, count: count) }
    return out
  }

  func testWriteReadRoundTripAndZeroFill() {
    let ring = AudioOutputRing(minimumCapacity: 2048)
    XCTAssertEqual(write(ring, [1, 2, 3]), 3)

    XCTAssertEqual(read(ring, 5), [1, 2, 3, 0, 0], "shortfall must zero-fill")
  }

  func testWriteDropsNewestOnOverflow() {
    let ring = AudioOutputRing(minimumCapacity: 2048) // capacity == 2048
    let fill = (0..<2048).map(Double.init)
    XCTAssertEqual(write(ring, fill), 2048, "a full ring accepts exactly its capacity")

    XCTAssertEqual(write(ring, [9, 9, 9]), 0, "writes to a full ring are dropped (drop-newest)")

    let out = read(ring, 2048)
    XCTAssertEqual(out.first, 0)
    XCTAssertEqual(out.last, 2047, "the oldest samples survive; the newest overflow is dropped")
  }

  func testWriteAcceptsOnlyWhatFits() {
    let ring = AudioOutputRing(minimumCapacity: 2048)
    XCTAssertEqual(write(ring, Array(repeating: 1.0, count: 2046)), 2046) // 2 free

    XCTAssertEqual(write(ring, [7, 8, 9, 10]), 2, "only the 2 free slots are filled")
  }

  func testClearEmptiesOutput() {
    let ring = AudioOutputRing(minimumCapacity: 2048)
    XCTAssertEqual(write(ring, [1, 2, 3]), 3)

    ring.clear()

    XCTAssertEqual(read(ring, 3), [0, 0, 0], "clear() drops queued samples; read zero-fills")

    XCTAssertEqual(write(ring, [9, 9]), 2)
    XCTAssertEqual(read(ring, 2), [9, 9], "fresh write after clear reads back cleanly")
  }
}

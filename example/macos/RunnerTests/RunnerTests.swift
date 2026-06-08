import Cocoa
import FlutterMacOS
import XCTest

// Public import is sufficient: RingBuffer is a `public struct` and every
// member exercised below (init/writeBlock/read/isFull) is public, so this
// compiles without the plugin module being built for `@testable`.
import audio_io

class RunnerTests: XCTestCase {

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

}

// MARK: - RingBuffer.writeBlock overflow coverage
//
// `RingBuffer.writeBlock` (PR #7, commit 7e9956e9) was changed from
// refuse-the-whole-block-on-overflow to drop-oldest / keep-newest. The
// arithmetic is correct but off-by-one-prone and had zero test coverage.
// These cases lock the invariant against future refactors. The `RingBuffer`
// struct is duplicated verbatim in the iOS and macOS plugins, so this same
// suite lives in both `example/ios` and `example/macos` RunnerTests.
class RingBufferWriteBlockTests: XCTestCase {

  /// Drains every queued sample in read order so we can assert ordering.
  private func drain<T>(_ buffer: inout RingBuffer<T>) -> [T] {
    var out: [T] = []
    while let value = buffer.read() {
      out.append(value)
    }
    return out
  }

  // Case 1: a block that fills the remaining space *exactly* drops nothing.
  func testWriteBlockExactFullBoundaryDiscardsNothing() {
    var buffer = RingBuffer<Int>(count: 8)
    XCTAssertEqual(buffer.writeBlock([1, 2, 3]), 0)

    // 5 free slots, write exactly 5 -> fills the ring with no eviction.
    let discarded = buffer.writeBlock([4, 5, 6, 7, 8])
    XCTAssertEqual(discarded, 0, "filling remaining space exactly must not drop the oldest")
    XCTAssertTrue(buffer.isFull)

    XCTAssertEqual(drain(&buffer), [1, 2, 3, 4, 5, 6, 7, 8])
  }

  // Case 2: a block larger than the free space evicts the oldest queued
  // samples, keeps the newest, and reports the correct discarded count.
  func testWriteBlockDropsOldestOnOverflow() {
    var buffer = RingBuffer<Int>(count: 8)
    XCTAssertEqual(buffer.writeBlock([1, 2, 3, 4, 5, 6]), 0) // 6 queued, 2 free

    // writeCount 4 with only 2 free -> overflow 2: oldest 1,2 evicted.
    let discarded = buffer.writeBlock([7, 8, 9, 10])
    XCTAssertEqual(discarded, 2, "overflow beyond free space must equal evicted-oldest count")
    XCTAssertTrue(buffer.isFull, "buffer must end exactly full")

    // Newest writeCount samples retained in order; oldest two are gone.
    XCTAssertEqual(drain(&buffer), [3, 4, 5, 6, 7, 8, 9, 10])
  }

  // Case 3: a block larger than the whole ring keeps only its most recent
  // `array.count` samples; discarded == startOffset + previously-queued.
  func testWriteBlockLargerThanRingRetainsOnlyMostRecent() {
    var buffer = RingBuffer<Int>(count: 4)
    XCTAssertEqual(buffer.writeBlock([1, 2]), 0) // 2 previously queued

    // Block of 6 into a ring of 4: startOffset = 6 - 4 = 2 (head dropped),
    // and the 2 previously-queued samples are evicted to make room.
    let discarded = buffer.writeBlock([10, 11, 12, 13, 14, 15])
    XCTAssertEqual(discarded, 4, "discarded == startOffset (2) + previously-queued (2)")
    XCTAssertTrue(buffer.isFull)

    // Only the most recent array.count (4) samples of the block survive.
    XCTAssertEqual(drain(&buffer), [12, 13, 14, 15])
  }

  // Case 4: an empty block returns 0 and mutates nothing.
  func testWriteBlockEmptyIsNoOp() {
    var buffer = RingBuffer<Int>(count: 4)
    XCTAssertEqual(buffer.writeBlock([1, 2]), 0)

    let discarded = buffer.writeBlock([])
    XCTAssertEqual(discarded, 0, "count == 0 returns 0")
    XCTAssertFalse(buffer.isFull, "empty block must not change occupancy")

    // Existing contents and order are untouched.
    XCTAssertEqual(drain(&buffer), [1, 2])
  }
}

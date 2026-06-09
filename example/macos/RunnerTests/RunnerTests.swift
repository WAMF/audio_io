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

// MARK: - RingBuffer.clear coverage (PR #7, commit 9053b63)
//
// `clearOutput()` flushes the OUTPUT ring buffer on a barge-in / interruption.
// It bottoms out in `RingBuffer.clear()`, which resets `readIndex`/`writeIndex`
// to 0 without zeroing the backing array. That reset is off-by-one-prone (a
// stale index would surface old samples or corrupt the next write), and the new
// public API shipped with zero test coverage. This case locks the invariant.
//
// Like `RingBufferWriteBlockTests`, the `RingBuffer` struct is duplicated
// verbatim between the iOS and macOS plugins, so this same suite lives in both
// `example/ios` and `example/macos` RunnerTests; the macOS target is the one
// wired into CI (see .github/workflows/xctest.yml).
class RingBufferClearTests: XCTestCase {

  // clear() must empty the queue, and a fresh write afterwards must read back
  // exactly the new samples in order — proving both indices reset cleanly and
  // no stale data survives. Fail-if-reverted: making clear() a no-op (or
  // breaking the readIndex/writeIndex reset) leaves the old [1,2,3] queued, so
  // isEmpty, read()==nil, and the [9,9] read-back all fail.
  func testRingBufferClearEmptiesOutput() {
    var buffer = RingBuffer<Float>(count: 8)

    // Queue some playback, then flush it as clearOutput() would.
    XCTAssertEqual(buffer.writeBlock([1, 2, 3]), 0)
    XCTAssertFalse(buffer.isEmpty, "buffer holds queued samples before clear")

    buffer.clear()

    XCTAssertTrue(buffer.isEmpty, "clear() must drop all queued samples")
    XCTAssertNil(buffer.read(), "clear() must leave nothing to read")
    XCTAssertFalse(buffer.isFull)

    // A fresh write after the reset must produce exactly the new samples with
    // no stale data and no index corruption.
    XCTAssertEqual(buffer.writeBlock([9, 9]), 0)
    XCTAssertEqual(buffer.read(), 9 as Float?, "first read after clear+write is the new sample")
    XCTAssertEqual(buffer.read(), 9 as Float?, "second read after clear+write is the new sample")
    XCTAssertNil(buffer.read(), "only the two freshly written samples are present")
    XCTAssertTrue(buffer.isEmpty, "buffer is drained again after reading both samples")
  }
}

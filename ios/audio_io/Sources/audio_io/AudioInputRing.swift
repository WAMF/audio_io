import Foundation

// SHARED SOURCE — single definition of AudioInputRing compiled by BOTH the
// iOS and macOS plugin pods. The macOS copy
// (macos/audio_io/Sources/audio_io/AudioInputRing.swift) is a symlink to this
// file, so the two platforms cannot drift. Edit here; the symlink follows.

/// Single-producer single-consumer ring buffer for the audio *input* path.
///
/// Mirrors `AudioOutputRing`, but stores plain `Float` (the AVAudioEngine
/// capture format is Float32, so keeping the ring Float32 end-to-end avoids a
/// per-sample Double conversion on the realtime render thread and halves the
/// bytes moved). The producer is the `AVAudioSinkNode` render block; the
/// consumer is the Dart FFI poll loop (`audio_io_apple_input_read`), which may
/// run on a dedicated audio isolate.
///
/// Fixed power-of-two storage, monotonic 64-bit indices (no wrap accounting to
/// get wrong), and an `os_unfair_lock` — which donates priority to the holder,
/// unlike a `DispatchQueue` — held only for short bulk copies, so the realtime
/// render thread never waits on descheduled consumer work.
public final class AudioInputRing {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int
    private var head = 0  // total samples written (producer: render thread)
    private var tail = 0  // total samples read (consumer: Dart poll)
    private let lockPtr: UnsafeMutablePointer<os_unfair_lock>

    public init(minimumCapacity: Int) {
        var cap = 2048
        while cap < minimumCapacity { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        storage = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        storage.initialize(repeating: 0, count: cap)
        lockPtr = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lockPtr.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deallocate()
        lockPtr.deallocate()
    }

    /// Writes as many samples as fit; the newest excess is dropped (matching
    /// `AudioOutputRing`). With the consumer draining the whole ring every
    /// poll, an overflow only happens if the poll loop stalls for longer than
    /// the ring holds — a pathological case, not the steady state.
    @discardableResult
    public func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
        os_unfair_lock_lock(lockPtr)
        let free = capacity - (head - tail)
        let accepted = min(samples.count, free)
        var index = head
        for i in 0..<accepted {
            storage[index & mask] = samples[i]
            index += 1
        }
        head = index
        os_unfair_lock_unlock(lockPtr)
        return accepted
    }

    /// Reads up to [maxCount] queued samples into [out]; returns the number
    /// actually read (0 when empty). Unlike `AudioOutputRing.read`, the
    /// shortfall is *not* zero-filled — the input consumer wants exactly the
    /// samples that are available, never synthesized silence.
    public func read(into out: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        os_unfair_lock_lock(lockPtr)
        let count = min(maxCount, head - tail)
        var index = tail
        for i in 0..<count {
            out[i] = storage[index & mask]
            index += 1
        }
        tail = index
        os_unfair_lock_unlock(lockPtr)
        return count
    }

    /// Number of samples queued for reading.
    public var availableToRead: Int {
        os_unfair_lock_lock(lockPtr)
        let n = head - tail
        os_unfair_lock_unlock(lockPtr)
        return n
    }

    public func clear() {
        os_unfair_lock_lock(lockPtr)
        tail = head
        os_unfair_lock_unlock(lockPtr)
    }
}

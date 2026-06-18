import Foundation

// SHARED SOURCE — single definition of AudioOutputRing compiled by BOTH the
// iOS and macOS plugin pods. The macOS copy (macos/Classes/AudioOutputRing.swift)
// is a symlink to this file, so the two platforms can no longer drift. Edit
// here; the symlink follows automatically.

/// Single-producer single-consumer ring buffer for the audio output path.
///
/// Fixed power-of-two storage of plain Doubles, monotonic 64-bit indices
/// (no wrap accounting to get wrong), and an os_unfair_lock - which donates
/// priority to the holder, unlike a DispatchQueue - held only for short
/// bulk copies, so the realtime render thread never waits on descheduled
/// main-thread work.
public final class AudioOutputRing {
    private let storage: UnsafeMutablePointer<Double>
    private let capacity: Int
    private let mask: Int
    private var head = 0  // total samples written
    private var tail = 0  // total samples read
    private let lockPtr: UnsafeMutablePointer<os_unfair_lock>

    public init(minimumCapacity: Int) {
        var cap = 2048
        while cap < minimumCapacity { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        storage = UnsafeMutablePointer<Double>.allocate(capacity: cap)
        storage.initialize(repeating: 0, count: cap)
        lockPtr = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lockPtr.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deallocate()
        lockPtr.deallocate()
    }

    /// Writes as many samples as fit; the excess is dropped.
    @discardableResult
    public func write(_ samples: UnsafeBufferPointer<Double>) -> Int {
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

    /// Fills [out] with up to [count] samples; the shortfall is zero-filled.
    public func read(into out: UnsafeMutableBufferPointer<Double>, count: Int) {
        os_unfair_lock_lock(lockPtr)
        let available = min(count, head - tail)
        var index = tail
        for i in 0..<available {
            out[i] = storage[index & mask]
            index += 1
        }
        tail = index
        os_unfair_lock_unlock(lockPtr)
        if available < count {
            for i in available..<count {
                out[i] = 0
            }
        }
    }

    public func clear() {
        os_unfair_lock_lock(lockPtr)
        tail = head
        os_unfair_lock_unlock(lockPtr)
    }
}

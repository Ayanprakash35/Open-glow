import Dispatch
import os

/// Single-producer/single-consumer stereo ring buffer for Float32 frames.
///
/// The producer is the ScreenCaptureKit sample-delivery callback, a real-time-ish thread that must
/// never allocate or block for long. The consumer is `BeatDetector`'s analysis, which wants
/// "the most recent N frames" each tick rather than a strict once-only dequeue.
///
/// Both channels live under one lock so a read can never pair left and right from different
/// capture callbacks — with two independently locked buffers, a callback landing between the two
/// reads shifted one channel by a whole chunk (~21ms) and made the mono mix comb-filter.
///
/// `sequence` counts every frame ever written. The reader compares it between ticks to tell fresh
/// audio from a stale window: without it, a producer that stops (stream error, sleep, a paused
/// player) left the last 2048 frames being re-analyzed forever, freezing the glow at its last level.
///
/// The lock is `OSAllocatedUnfairLock` — heap-allocated, so its address is stable (a Swift `var`
/// of `os_unfair_lock` isn't formally guaranteed to be), and uncontended it costs a few
/// nanoseconds with no syscall. Copies are two contiguous `update(from:count:)` segments at most,
/// not a per-sample loop.
///
/// A write observer lets the reader wake when audio lands instead of polling for it. Signalling
/// it is a lock-free merge into a dispatch source, sent after the lock is released, so the
/// producer still never blocks or allocates.
final class AudioRingBuffer: @unchecked Sendable {
    let capacity: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private var filledCount = 0
    private var totalWritten: UInt64 = 0
    private var writeObserver: DispatchSourceUserDataAdd?
    private var observerMinimumFrames = 1
    private var framesSinceSignal = 0
    private let lock = OSAllocatedUnfairLock()

    init(capacity: Int) {
        precondition(capacity > 0, "AudioRingBuffer capacity must be positive")
        self.capacity = capacity
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// Appends `count` frames, overwriting the oldest on overflow rather than blocking — a full
    /// buffer means analysis fell behind, and dropping a few milliseconds of audio is far better
    /// than stalling the capture thread. Then signals the write observer, if one is due.
    func write(left leftSamples: UnsafePointer<Float>, right rightSamples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        store(left: leftSamples, right: rightSamples, count: count)
        var due: DispatchSourceUserDataAdd?
        if let writeObserver {
            framesSinceSignal += count
            if framesSinceSignal >= observerMinimumFrames {
                due = writeObserver
                framesSinceSignal = 0
            }
        }
        lock.unlock()
        due?.add(data: 1)
    }

    /// Signals `observer` once at least `minimumFrames` frames have been written since it was
    /// last signalled, so the reader can wake for each usable amount of new audio; nil stops the
    /// signals. Pass a source on the reader's queue; signals coalesce while its handler is
    /// pending, and a cancelled source ignores them.
    func setWriteObserver(_ observer: DispatchSourceUserDataAdd?, minimumFrames: Int = 1) {
        lock.lock()
        defer { lock.unlock() }
        writeObserver = observer
        observerMinimumFrames = max(minimumFrames, 1)
        framesSinceSignal = 0
    }

    /// Copies `count` frames in at the write position. Call with the lock held.
    private func store(left leftSamples: UnsafePointer<Float>, right rightSamples: UnsafePointer<Float>, count: Int) {
        // Only the newest `capacity` frames can survive anyway.
        let skipped = max(0, count - capacity)
        var remaining = count - skipped
        var source = skipped
        while remaining > 0 {
            let chunk = min(remaining, capacity - writeIndex)
            (left + writeIndex).update(from: leftSamples + source, count: chunk)
            (right + writeIndex).update(from: rightSamples + source, count: chunk)
            writeIndex = (writeIndex + chunk) % capacity
            source += chunk
            remaining -= chunk
        }
        filledCount = min(capacity, filledCount + count)
        totalWritten &+= UInt64(count)
    }

    /// Copies up to `count` of the most recent frames (oldest first) into the destinations.
    /// Returns how many frames were available and the write sequence at the time of the read.
    /// Reads overlap between calls by design.
    func read(
        left leftOut: UnsafeMutablePointer<Float>,
        right rightOut: UnsafeMutablePointer<Float>,
        count: Int
    ) -> (available: Int, sequence: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        let n = min(count, filledCount)
        guard n > 0 else { return (0, totalWritten) }

        var readIndex = (writeIndex - n + capacity) % capacity
        var copied = 0
        while copied < n {
            let chunk = min(n - copied, capacity - readIndex)
            (leftOut + copied).update(from: left + readIndex, count: chunk)
            (rightOut + copied).update(from: right + readIndex, count: chunk)
            readIndex = (readIndex + chunk) % capacity
            copied += chunk
        }
        return (n, totalWritten)
    }

    /// Frames currently held and the write sequence, without copying anything — lets the reader
    /// skip a tick cheaply when nothing new has arrived.
    func status() -> (available: Int, sequence: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (filledCount, totalWritten)
    }

    /// Copies exactly `count` frames ending at write position `end` (a value of the sequence).
    /// Returns false, copying nothing, if any of those frames hasn't been written yet or has
    /// already been overwritten or reset away.
    func read(
        left leftOut: UnsafeMutablePointer<Float>,
        right rightOut: UnsafeMutablePointer<Float>,
        count: Int,
        endingAt end: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let oldest = totalWritten - UInt64(filledCount)
        guard count > 0, count <= capacity, end <= totalWritten, end >= oldest + UInt64(count) else { return false }

        // Position of `end` relative to the newest frame, mapped onto the storage.
        let framesAfterEnd = Int(totalWritten - end)
        var readIndex = ((writeIndex - framesAfterEnd - count) % capacity + capacity) % capacity
        var copied = 0
        while copied < count {
            let chunk = min(count - copied, capacity - readIndex)
            (leftOut + copied).update(from: left + readIndex, count: chunk)
            (rightOut + copied).update(from: right + readIndex, count: chunk)
            readIndex = (readIndex + chunk) % capacity
            copied += chunk
        }
        return true
    }

    /// Discards all buffered audio, so a restarted capture never analyzes frames from before the
    /// stop. The sequence deliberately keeps counting up: if it restarted at zero, a later value
    /// could coincidentally equal a reader's last-seen one and make fresh audio look stale.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        writeIndex = 0
        filledCount = 0
        framesSinceSignal = 0
    }
}

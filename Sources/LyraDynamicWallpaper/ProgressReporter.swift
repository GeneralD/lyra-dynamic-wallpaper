import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// Thread-safe single-line stderr progress reporter for the resolve → extract
/// → encode pipeline.
///
/// Line formatting is delegated to the pure `ProgressLine`; this type owns
/// only the mutable, lock-guarded state (cumulative frame counters, the last
/// render time for throttling, the spinner tick, the currently-drawn line's
/// length) and the actual writes. Safe to call from AVFoundation's callback
/// threads — same `NSLock` discipline as `FrameCollector` in
/// `FrameExtraction.swift`.
///
/// `now`/`write` are injectable so tests can drive the throttle deterministically
/// (a fake clock) and capture output (a fake sink) without touching a real
/// terminal or sleeping.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let isTTY: Bool
    private let minRedrawInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let write: @Sendable (String) -> Void

    private var extractCompleted = 0
    private var encodeCompleted = 0
    private var lastRenderTime = Date.distantPast
    private var lastLineLength = 0
    private var tick = -1

    init(
        isTTY: Bool = ProgressReporter.stderrIsTTY(),
        minRedrawInterval: TimeInterval = 0.08,
        now: @escaping @Sendable () -> Date = Date.init,
        write: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) {
        self.isTTY = isTTY
        self.minRedrawInterval = minRedrawInterval
        self.now = now
        self.write = write
    }

    static func stderrIsTTY() -> Bool { isatty(STDERR_FILENO) != 0 }

    // MARK: - Phase lifecycle

    /// Announce a phase's start. On a TTY this draws the label in place
    /// (no trailing newline) so the phase's own live updates — if any —
    /// overwrite it on the same line; a phase with no live updates (resolve)
    /// leaves it on screen until `finishPhase` replaces it. On a non-TTY this
    /// is the only visible signal that the phase began, so it always prints a
    /// plain line.
    func phaseStarted(_ label: String) {
        lock.lock()
        defer { lock.unlock() }
        guard isTTY else {
            write(label + "\n")
            return
        }
        renderLine(label)
    }

    /// Terminate a dangling live line left by `phaseStarted`/a progress
    /// update whose phase never reached its `finished` call (e.g. the phase
    /// threw). No-op if nothing is currently drawn — the normal, happy-path
    /// case, since `finishPhase` already resets `lastLineLength` to 0.
    ///
    /// Without this, an error thrown mid-phase leaves a `\r`-anchored line on
    /// screen with no trailing newline; ArgumentParser's error text then
    /// overwrites it from column 0, producing a garbled, half-overlapped
    /// line — the exact "can't tell what's happening" confusion this feature
    /// exists to remove, just moved to the failure path.
    func finalizeIfDangling() {
        lock.lock()
        defer { lock.unlock() }
        guard isTTY, lastLineLength > 0 else { return }
        write("\n")
        lastLineLength = 0
    }

    /// Clear the live line (if any was drawn) and print a fixed summary that
    /// survives — always emitted, TTY or not.
    private func finishPhase(_ summary: String) {
        lock.lock()
        defer { lock.unlock() }
        if isTTY, lastLineLength > 0 {
            write("\r" + String(repeating: " ", count: lastLineLength) + "\r")
        }
        lastLineLength = 0
        write(summary + "\n")
    }

    // MARK: - Resolve phase

    /// No live per-item hook (see design notes) — resolve goes straight from
    /// `phaseStarted` to this fixed summary.
    func resolveFinished(clipCount: Int) {
        finishPhase(ProgressLine.resolveSummary(total: clipCount))
    }

    // MARK: - Extract phase

    /// Call once per frame callback (success or failure — mirrors
    /// `FrameCollector.remaining`, which decrements either way). Increments
    /// the cumulative counter unconditionally, then attempts a throttled
    /// redraw.
    func extractFrameCompleted(total: Int, clipIndex: Int, clipCount: Int) {
        let completed = lock.withLock {
            extractCompleted += 1
            return extractCompleted
        }
        renderThrottled { tick in
            ProgressLine.extract(tick: tick, completed: completed, total: total, clipIndex: clipIndex, clipCount: clipCount)
        }
    }

    func extractFinished(total: Int, clipCount: Int) {
        finishPhase(ProgressLine.extractSummary(total: total, clipCount: clipCount))
    }

    // MARK: - Encode phase

    func encodeFrameCompleted(total: Int) {
        let completed = lock.withLock {
            encodeCompleted += 1
            return encodeCompleted
        }
        renderThrottled { tick in ProgressLine.encode(tick: tick, completed: completed, total: total) }
    }

    func encodeFinished(total: Int) {
        finishPhase(ProgressLine.encodeSummary(total: total))
    }

    // MARK: - Rendering

    /// Redraw the live line if enough wall-clock time passed since the last
    /// redraw. No-op entirely on a non-TTY (no live line ever drawn there).
    private func renderThrottled(_ makeLine: (Int) -> String) {
        guard isTTY else { return }
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        guard current.timeIntervalSince(lastRenderTime) >= minRedrawInterval else { return }
        lastRenderTime = current
        tick += 1
        renderLine(makeLine(tick))
    }

    /// Write `line` over the previous one, padding with spaces to erase any
    /// leftover tail from a longer previous line. Must be called with `lock`
    /// held.
    private func renderLine(_ line: String) {
        let trailingClear = String(repeating: " ", count: max(0, lastLineLength - line.count))
        write("\r" + line + trailingClear)
        lastLineLength = line.count
    }
}

extension NSLock {
    /// Run `body` under the lock, returning its result. Keeps call sites free
    /// of manual `lock()`/`defer { unlock() }` pairs for simple read-modify.
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

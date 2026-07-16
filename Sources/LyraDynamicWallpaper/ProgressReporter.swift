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
/// length). Every public method follows the same shape: mutate state and
/// compute the text to write while `lock` is held, then release `lock`
/// BEFORE calling the (possibly slow/blocking, externally-injectable) `write`
/// closure — same discipline as `FrameCollector` in `FrameExtraction.swift`,
/// which releases its own lock before calling back out. This keeps a stalled
/// `write` (e.g. flow-controlled stderr) from blocking other threads' cheap
/// counter bumps. Safe to call from AVFoundation's callback threads.
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
        let text = lock.withLock { () -> String in
            guard isTTY else { return label + "\n" }
            return prepareLine(label)
        }
        write(text)
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
        let text: String? = lock.withLock {
            guard isTTY, lastLineLength > 0 else { return nil }
            lastLineLength = 0
            return "\n"
        }
        guard let text else { return }
        write(text)
    }

    /// Clear the live line (if any was drawn) and print a fixed summary that
    /// survives — always emitted, TTY or not.
    private func finishPhase(_ summary: String) {
        let text = lock.withLock { () -> String in
            var text = ""
            if isTTY, lastLineLength > 0 {
                text += "\r" + String(repeating: " ", count: lastLineLength) + "\r"
            }
            lastLineLength = 0
            text += summary + "\n"
            return text
        }
        write(text)
    }

    /// Print a line that must interleave safely with whatever live line is
    /// currently drawn — e.g. a mid-phase warning. Pass this method as (or
    /// wrap it in) the `warn` closure threaded into `WallpaperSource` /
    /// `FrameExtraction` so skip/failure warnings never collide with this
    /// reporter's own `\r`-anchored line (see `Support.warn`/`warningLine`).
    /// Clears the live line first (identical erase sequence to `finishPhase`)
    /// so the warning never overlaps/corrupts it, then leaves the tracked
    /// line length at 0 so the next progress redraw starts clean. Always
    /// emitted, TTY or not (a non-TTY has no live line to clear, so this
    /// degrades to a plain line).
    func interject(_ line: String) {
        let text = lock.withLock { () -> String in
            var text = ""
            if isTTY, lastLineLength > 0 {
                text += "\r" + String(repeating: " ", count: lastLineLength) + "\r"
            }
            lastLineLength = 0
            text += line + "\n"
            return text
        }
        write(text)
    }

    // MARK: - Resolve phase

    /// No live per-item hook (see design notes) — resolve goes straight from
    /// `phaseStarted` to this fixed summary.
    func resolveFinished(clipCount: Int) {
        finishPhase(ProgressLine.resolveSummary(total: clipCount))
    }

    // MARK: - Extract phase

    /// Call once per frame callback (success or failure — mirrors
    /// `FrameCollector.reported`, which increments either way). Bumps the
    /// cumulative counter unconditionally, then attempts a throttled redraw.
    func extractFrameCompleted(total: Int, clipIndex: Int, clipCount: Int) {
        let text = bumpAndRenderThrottled(
            { extractCompleted += 1 },
            makeLine: { tick in
                ProgressLine.extract(tick: tick, completed: extractCompleted, total: total, clipIndex: clipIndex, clipCount: clipCount)
            }
        )
        guard let text else { return }
        write(text)
    }

    func extractFinished(total: Int, clipCount: Int) {
        finishPhase(ProgressLine.extractSummary(total: total, clipCount: clipCount))
    }

    // MARK: - Encode phase

    func encodeFrameCompleted(total: Int) {
        let text = bumpAndRenderThrottled(
            { encodeCompleted += 1 },
            makeLine: { tick in ProgressLine.encode(tick: tick, completed: encodeCompleted, total: total) }
        )
        guard let text else { return }
        write(text)
    }

    func encodeFinished(total: Int) {
        finishPhase(ProgressLine.encodeSummary(total: total))
    }

    // MARK: - Rendering

    /// Apply `bumpCounter` and, on a TTY with the throttle window elapsed,
    /// compute the next line to draw via `makeLine` — all within a SINGLE
    /// lock acquisition. Splitting the counter bump and the throttle
    /// decision across two separate lock acquisitions (as an earlier version
    /// did) let two concurrent callers interleave: caller A bumps to 5,
    /// caller B bumps to 6 and wins the throttle window and draws "6/…",
    /// then caller A's own (now stale) throttle check can still pass and
    /// redraw "5/…" over it — the display visibly regresses. Doing both
    /// under one lock makes "bump, then maybe draw" atomic per call, so the
    /// line drawn always reflects the count as of that same call.
    ///
    /// Returns the text to write, if any; the caller writes it AFTER this
    /// method returns (lock already released) — `write` can be slow/blocking
    /// I/O and must never run while `lock` is held (see the class doc).
    private func bumpAndRenderThrottled(_ bumpCounter: () -> Void, makeLine: (Int) -> String) -> String? {
        lock.withLock {
            bumpCounter()
            guard isTTY else { return nil }
            let current = now()
            guard current.timeIntervalSince(lastRenderTime) >= minRedrawInterval else { return nil }
            lastRenderTime = current
            tick += 1
            return prepareLine(makeLine(tick))
        }
    }

    /// Compute `line` padded to erase any leftover tail from a longer
    /// previous line, and update `lastLineLength` to match. Must be called
    /// with `lock` held; returns the text for the caller to `write` AFTER
    /// releasing the lock.
    private func prepareLine(_ line: String) -> String {
        let trailingClear = String(repeating: " ", count: max(0, lastLineLength - line.count))
        lastLineLength = line.count
        return "\r" + line + trailingClear
    }
}

extension NSLock {
    /// Run `body` under the lock, returning its result. Keeps call sites free
    /// of manual `lock()`/`defer { unlock() }` pairs for simple read-modify.
    /// Shared across the module (also used by `FrameExtraction`'s collector lock).
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

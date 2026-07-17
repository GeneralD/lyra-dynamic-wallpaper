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
/// compute the text to write while `lock` is held, then ENQUEUE that text
/// onto the serial `outputQueue` — still under `lock`, because enqueueing is
/// cheap and non-blocking, and doing it under the same lock that ordered the
/// state transition makes the queue's FIFO order match state-transition
/// order. The (possibly slow/blocking, externally-injectable) `write` closure
/// then runs on the queue's own thread: a stalled write (e.g. flow-controlled
/// stderr) can neither block other threads' cheap counter bumps NOR be
/// overtaken by a later transition's write — later chunks just queue up
/// behind it. Safe to call from AVFoundation's callback threads.
///
/// Phase-boundary methods (`phaseStarted`, `finishPhase`,
/// `finalizeIfDangling`) drain the queue before returning: they are called
/// from the command's own task (never a frame callback), they are rare, and
/// draining there guarantees the final summaries reach stderr before the
/// process exits.
///
/// `now`/`write` are injectable so tests can drive the throttle deterministically
/// (a fake clock) and capture output (a fake sink) without touching a real
/// terminal or sleeping.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let outputQueue = DispatchQueue(label: "lyra-dynamic-wallpaper.progress-output")
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
        lock.withLock {
            emit(isTTY ? prepareLine(label) : label + "\n")
        }
        flushOutput()
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
        lock.withLock {
            guard isTTY, lastLineLength > 0 else { return }
            lastLineLength = 0
            emit("\n")
        }
        flushOutput()
    }

    /// Clear the live line (if any was drawn) and print a fixed summary that
    /// survives — always emitted, TTY or not.
    private func finishPhase(_ summary: String) {
        lock.withLock {
            emit(eraseLiveLine() + summary + "\n")
        }
        flushOutput()
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
    /// degrades to a plain line). No queue drain — this can be called from a
    /// frame callback thread, which must never wait on stderr I/O.
    func interject(_ line: String) {
        lock.withLock {
            emit(eraseLiveLine() + line + "\n")
        }
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
        bumpAndRenderThrottled(
            { extractCompleted += 1 },
            makeLine: { tick in
                ProgressLine.extract(tick: tick, completed: extractCompleted, total: total, clipIndex: clipIndex, clipCount: clipCount)
            }
        )
    }

    func extractFinished(total: Int, clipCount: Int) {
        finishPhase(ProgressLine.extractSummary(total: total, clipCount: clipCount))
    }

    // MARK: - Encode phase

    func encodeFrameCompleted(total: Int) {
        bumpAndRenderThrottled(
            { encodeCompleted += 1 },
            makeLine: { tick in ProgressLine.encode(tick: tick, completed: encodeCompleted, total: total) }
        )
    }

    func encodeFinished(total: Int) {
        finishPhase(ProgressLine.encodeSummary(total: total))
    }

    // MARK: - Output ordering

    /// Block until every chunk enqueued so far has been written. Called at
    /// phase boundaries (command task only, never a frame callback) and by
    /// tests before asserting on the sink.
    func flushOutput() {
        outputQueue.sync {}
    }

    /// Hand `text` to the serial output queue. Must be called with `lock`
    /// held — enqueue order under the state lock IS the display order the
    /// queue preserves. The enqueue itself never blocks; only the queue's
    /// worker thread ever runs `write`.
    private func emit(_ text: String) {
        outputQueue.async { [write] in write(text) }
    }

    // MARK: - Rendering

    /// Apply `bumpCounter` and, on a TTY with the throttle window elapsed,
    /// enqueue the next line to draw via `makeLine` — all within a SINGLE
    /// lock acquisition. Splitting the counter bump and the throttle
    /// decision across two separate lock acquisitions (as an earlier version
    /// did) let two concurrent callers interleave: caller A bumps to 5,
    /// caller B bumps to 6 and wins the throttle window and draws "6/…",
    /// then caller A's own (now stale) throttle check can still pass and
    /// redraw "5/…" over it — the display visibly regresses. Doing both
    /// under one lock makes "bump, then maybe draw" atomic per call, and
    /// enqueueing under that same lock keeps the write order identical to
    /// the state-transition order (see the class doc).
    private func bumpAndRenderThrottled(_ bumpCounter: () -> Void, makeLine: (Int) -> String) {
        lock.withLock {
            bumpCounter()
            guard isTTY else { return }
            let current = now()
            guard current.timeIntervalSince(lastRenderTime) >= minRedrawInterval else { return }
            lastRenderTime = current
            tick += 1
            emit(prepareLine(makeLine(tick)))
        }
    }

    /// The `\r`-erase sequence for whatever live line is currently drawn
    /// (empty on a non-TTY or when nothing is drawn), resetting the tracked
    /// length so the next redraw starts clean. Must be called with `lock`
    /// held.
    private func eraseLiveLine() -> String {
        let erase = isTTY && lastLineLength > 0
            ? "\r" + String(repeating: " ", count: lastLineLength) + "\r"
            : ""
        lastLineLength = 0
        return erase
    }

    /// Compute `line` padded to erase any leftover tail from a longer
    /// previous line, and update `lastLineLength` to match. Must be called
    /// with `lock` held; the caller enqueues the result via `emit`.
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

import Foundation
import Testing

@testable import LyraDynamicWallpaper

/// Captures every write, and lets a test drive time deterministically instead
/// of sleeping — `advance(by:)` moves the fake clock, no real delay involved.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 0)) { current = start }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}

private final class FakeSink: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [String] = []

    func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        chunks.append(text)
    }

    var joined: String {
        lock.lock()
        defer { lock.unlock() }
        return chunks.joined()
    }

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return chunks.count
    }
}

@Suite struct ProgressReporterTests {
    private func makeReporter(isTTY: Bool, clock: FakeClock, sink: FakeSink) -> ProgressReporter {
        ProgressReporter(isTTY: isTTY, minRedrawInterval: 0.08, now: clock.now, write: sink.write)
    }

    // MARK: - TTY: live line drawing

    @Test func firstProgressCallAlwaysRendersImmediately() {
        let clock = FakeClock()
        let sink = FakeSink()
        let reporter = makeReporter(isTTY: true, clock: clock, sink: sink)

        reporter.extractFrameCompleted(total: 10, clipIndex: 1, clipCount: 1)

        #expect(sink.writeCount == 1)
        #expect(sink.joined.contains("1/10"))
    }

    @Test func rapidCallsWithinThrottleWindowAreCoalesced() {
        let clock = FakeClock()
        let sink = FakeSink()
        let reporter = makeReporter(isTTY: true, clock: clock, sink: sink)

        // Ten calls with no clock movement — only the first should draw.
        for _ in 0..<10 { reporter.extractFrameCompleted(total: 100, clipIndex: 1, clipCount: 1) }

        #expect(sink.writeCount == 1)
    }

    @Test func callAfterThrottleWindowRendersAgain() {
        let clock = FakeClock()
        let sink = FakeSink()
        let reporter = makeReporter(isTTY: true, clock: clock, sink: sink)

        reporter.extractFrameCompleted(total: 100, clipIndex: 1, clipCount: 1)
        clock.advance(by: 0.09)
        reporter.extractFrameCompleted(total: 100, clipIndex: 1, clipCount: 1)

        #expect(sink.writeCount == 2)
    }

    @Test func cumulativeCounterAdvancesEvenWhenRenderIsThrottled() {
        let clock = FakeClock()
        let sink = FakeSink()
        let reporter = makeReporter(isTTY: true, clock: clock, sink: sink)

        for _ in 0..<5 { reporter.extractFrameCompleted(total: 100, clipIndex: 1, clipCount: 1) }
        clock.advance(by: 0.09)
        reporter.extractFrameCompleted(total: 100, clipIndex: 1, clipCount: 1)

        // The counter incremented on every call (6), even though only two
        // redraws happened — the visible line reflects the true count.
        #expect(sink.joined.contains("6/100"))
    }

    @Test func encodeAndExtractCountersAreIndependent() {
        let clock = FakeClock()
        let sink = FakeSink()
        let reporter = makeReporter(isTTY: true, clock: clock, sink: sink)

        reporter.extractFrameCompleted(total: 10, clipIndex: 1, clipCount: 1)
        clock.advance(by: 0.09)
        reporter.encodeFrameCompleted(total: 10)

        #expect(sink.joined.contains("1/10 (clip"))
        #expect(sink.joined.contains("1/10 frames"))
    }

    // MARK: - Line overwriting and cleanup

    @Test func shorterLineClearsTrailingCharactersFromLongerPrevious() {
        let clock = FakeClock()
        let sink = FakeSink()
        let reporter = makeReporter(isTTY: true, clock: clock, sink: sink)

        reporter.extractFrameCompleted(total: 1000, clipIndex: 3, clipCount: 5) // long line
        clock.advance(by: 0.09)
        reporter.encodeFrameCompleted(total: 1) // short line, different phase

        // The second write must pad with enough spaces to fully erase the
        // first (longer) line's tail.
        let writes = sink.joined.components(separatedBy: "\r").filter { !$0.isEmpty }
        #expect(writes.count == 2)
        #expect(writes[1].contains("  ")) // padding present
    }

    @Test func finishPhaseClearsTheLiveLineAndPrintsASummary() {
        let clock = FakeClock()
        let sink = FakeSink()
        let reporter = makeReporter(isTTY: true, clock: clock, sink: sink)

        reporter.extractFrameCompleted(total: 10, clipIndex: 1, clipCount: 1)
        reporter.extractFinished(total: 10, clipCount: 1)

        let output = sink.joined
        #expect(output.contains("\r"))
        #expect(output.hasSuffix("extracted 10 frames across 1 clip\n"))
    }

    @Test func finishPhaseIsANoOpClearWhenNoLiveLineWasEverDrawn() {
        let clock = FakeClock()
        let sink = FakeSink()
        let reporter = makeReporter(isTTY: true, clock: clock, sink: sink)

        // resolve has no live hook — phaseStarted draws the only line, then
        // resolveFinished must still clear exactly that.
        reporter.phaseStarted("resolving wallpapers …")
        reporter.resolveFinished(clipCount: 3)

        let output = sink.joined
        #expect(output.hasSuffix("resolved 3 clips\n"))
    }

    // MARK: - Non-TTY: milestones only, no live redraws

    @Test func nonTTYNeverDrawsALiveLine() {
        let clock = FakeClock()
        let sink = FakeSink()
        let reporter = makeReporter(isTTY: false, clock: clock, sink: sink)

        for _ in 0..<20 { reporter.extractFrameCompleted(total: 20, clipIndex: 1, clipCount: 1) }

        #expect(sink.writeCount == 0)
    }

    @Test func nonTTYPrintsPhaseStartAndFinishLinesOnly() {
        let clock = FakeClock()
        let sink = FakeSink()
        let reporter = makeReporter(isTTY: false, clock: clock, sink: sink)

        reporter.phaseStarted("extracting frames …")
        for _ in 0..<5 { reporter.extractFrameCompleted(total: 5, clipIndex: 1, clipCount: 1) }
        reporter.extractFinished(total: 5, clipCount: 1)

        #expect(sink.writeCount == 2)
        #expect(sink.joined == "extracting frames …\nextracted 5 frames across 1 clip\n")
    }

    @Test func nonTTYNeverEmitsCarriageReturns() {
        let clock = FakeClock()
        let sink = FakeSink()
        let reporter = makeReporter(isTTY: false, clock: clock, sink: sink)

        reporter.phaseStarted("resolving wallpapers …")
        reporter.resolveFinished(clipCount: 1)

        #expect(!sink.joined.contains("\r"))
    }

    // MARK: - Dangling line cleanup (phase threw before reaching `finished`)

    @Test func finalizeIfDanglingTerminatesAnUnfinishedLiveLine() {
        let clock = FakeClock()
        let sink = FakeSink()
        let reporter = makeReporter(isTTY: true, clock: clock, sink: sink)

        // Simulates a phase that threw between phaseStarted and its
        // `finished` call — no summary was ever printed.
        reporter.phaseStarted("resolving wallpapers …")
        reporter.finalizeIfDangling()

        #expect(sink.joined == "\rresolving wallpapers …\n")
    }

    @Test func finalizeIfDanglingIsANoOpAfterANormalFinish() {
        let clock = FakeClock()
        let sink = FakeSink()
        let reporter = makeReporter(isTTY: true, clock: clock, sink: sink)

        reporter.phaseStarted("resolving wallpapers …")
        reporter.resolveFinished(clipCount: 2)
        let beforeCount = sink.writeCount

        reporter.finalizeIfDangling()

        #expect(sink.writeCount == beforeCount)
    }

    @Test func finalizeIfDanglingIsANoOpOnNonTTY() {
        let clock = FakeClock()
        let sink = FakeSink()
        let reporter = makeReporter(isTTY: false, clock: clock, sink: sink)

        reporter.phaseStarted("resolving wallpapers …")
        reporter.finalizeIfDangling()

        #expect(sink.joined == "resolving wallpapers …\n")
    }

    // MARK: - Interjection (warn() coordination — must not corrupt a live line)

    @Test func interjectClearsALiveLineBeforePrintingTheMessage() {
        let clock = FakeClock()
        let sink = FakeSink()
        let reporter = makeReporter(isTTY: true, clock: clock, sink: sink)

        reporter.extractFrameCompleted(total: 10, clipIndex: 1, clipCount: 1) // draws a live line
        reporter.interject("lyra-dynamic-wallpaper: warning: could not resolve foo.mp4 — skipping")

        // The live line must be erased (its own \r + spaces + \r) before the
        // warning is printed, exactly like finishPhase — never appended onto
        // the same visual line.
        #expect(sink.joined.hasSuffix("lyra-dynamic-wallpaper: warning: could not resolve foo.mp4 — skipping\n"))
        #expect(sink.joined.contains("\r"))
    }

    @Test func interjectResetsLineStateSoTheNextRedrawStartsClean() {
        let clock = FakeClock()
        let sink = FakeSink()
        let reporter = makeReporter(isTTY: true, clock: clock, sink: sink)

        reporter.extractFrameCompleted(total: 1000, clipIndex: 3, clipCount: 5) // long line
        reporter.interject("warning")
        clock.advance(by: 0.09)
        reporter.encodeFrameCompleted(total: 1) // short line, unrelated phase

        // If interject left the old (long) lastLineLength in place, this
        // short redraw would still be padded to erase the long line's tail;
        // instead it should draw as if nothing was on screen.
        let lastWrite = sink.joined.components(separatedBy: "\r").last ?? ""
        #expect(!lastWrite.contains("  "))
    }

    @Test func interjectOnNonTTYJustPrintsTheMessage() {
        let clock = FakeClock()
        let sink = FakeSink()
        let reporter = makeReporter(isTTY: false, clock: clock, sink: sink)

        reporter.interject("lyra-dynamic-wallpaper: warning: empty trim range — skipping")

        #expect(sink.joined == "lyra-dynamic-wallpaper: warning: empty trim range — skipping\n")
    }

    // MARK: - TTY: phaseStarted is visible immediately (no silent phases)

    @Test func phaseStartedIsVisibleOnTTYEvenBeforeAnyLiveUpdate() {
        let clock = FakeClock()
        let sink = FakeSink()
        let reporter = makeReporter(isTTY: true, clock: clock, sink: sink)

        reporter.phaseStarted("resolving wallpapers …")

        // Regression: a phase with no live-progress hook (resolve) must not
        // leave the terminal blank from process start until it finishes.
        #expect(sink.writeCount == 1)
        #expect(sink.joined.contains("resolving wallpapers …"))
    }
}

import Foundation
import Testing

@testable import LyraDynamicWallpaper

@Suite struct ProgressLineTests {
    // MARK: - Spinner

    @Test func spinnerCyclesThroughAllFrames() {
        let seen = (0..<ProgressLine.spinnerFrames.count).map { ProgressLine.spinner(tick: $0) }
        #expect(seen == ProgressLine.spinnerFrames)
    }

    @Test func spinnerWrapsAroundPastTheLastFrame() {
        let count = ProgressLine.spinnerFrames.count
        #expect(ProgressLine.spinner(tick: count) == ProgressLine.spinnerFrames[0])
        #expect(ProgressLine.spinner(tick: count + 3) == ProgressLine.spinnerFrames[3])
    }

    @Test func spinnerHandlesNegativeTicksDefensively() {
        // Never produced by ProgressReporter (tick only increments from -1),
        // but the pure function must not crash if ever called with one.
        #expect(ProgressLine.spinner(tick: -1) == ProgressLine.spinnerFrames.last)
    }

    // MARK: - Bar

    @Test func barIsEmptyWhenTotalIsZero() {
        #expect(ProgressLine.bar(completed: 0, total: 0).isEmpty)
    }

    @Test func barIsEmptyAtZeroWidth() {
        #expect(ProgressLine.bar(completed: 5, total: 10, width: 0).isEmpty)
    }

    @Test func barShowsZeroPercentAtStart() {
        #expect(ProgressLine.bar(completed: 0, total: 100, width: 10) == "[          ] 0%")
    }

    @Test func barShowsHundredPercentAtCompletion() {
        #expect(ProgressLine.bar(completed: 100, total: 100, width: 10) == "[==========] 100%")
    }

    @Test func barClampsCompletedBeyondTotal() {
        // An over-count (shouldn't normally happen) must not overflow the bar
        // or report over 100%.
        #expect(ProgressLine.bar(completed: 999, total: 100, width: 10) == "[==========] 100%")
    }

    @Test func barShowsAHeadAtPartialProgress() {
        let bar = ProgressLine.bar(completed: 36, total: 100, width: 20)
        #expect(bar.contains(">"))
        #expect(bar.hasSuffix("36%"))
    }

    // MARK: - Phase lines

    @Test func resolveLineIncludesSpinnerAndCounts() {
        let line = ProgressLine.resolve(tick: 0, resolved: 3, total: 5)
        #expect(line == "\(ProgressLine.spinnerFrames[0]) resolving wallpapers … 3/5 clips")
    }

    @Test func extractLineIncludesClipPositionAndBar() {
        let line = ProgressLine.extract(tick: 1, completed: 512, total: 1440, clipIndex: 2, clipCount: 5)
        #expect(line.contains("512/1440"))
        #expect(line.contains("(clip 2/5)"))
        #expect(line.contains("["))
        #expect(line.hasPrefix(String(ProgressLine.spinnerFrames[1])))
    }

    @Test func extractLineOmitsBarWhenTotalIsZero() {
        let line = ProgressLine.extract(tick: 0, completed: 0, total: 0, clipIndex: 1, clipCount: 1)
        #expect(!line.contains("["))
    }

    @Test func encodeLineIncludesCounts() {
        let line = ProgressLine.encode(tick: 4, completed: 1440, total: 1440)
        #expect(line.contains("1440/1440 frames"))
        #expect(line.hasPrefix(String(ProgressLine.spinnerFrames[4])))
    }

    // MARK: - Finished summaries (no spinner — the phase is over)

    @Test func resolveSummaryHasNoSpinnerAndPluralizes() {
        #expect(ProgressLine.resolveSummary(total: 5) == "resolved 5 clips")
        #expect(ProgressLine.resolveSummary(total: 1) == "resolved 1 clip")
        #expect(!ProgressLine.resolveSummary(total: 5).contains(where: { ProgressLine.spinnerFrames.contains($0) }))
    }

    @Test func extractSummaryMentionsFramesAndClips() {
        #expect(ProgressLine.extractSummary(total: 1440, clipCount: 5) == "extracted 1440 frames across 5 clips")
        #expect(ProgressLine.extractSummary(total: 1, clipCount: 1) == "extracted 1 frame across 1 clip")
    }

    @Test func encodeSummaryMentionsFrames() {
        #expect(ProgressLine.encodeSummary(total: 1440) == "encoded 1440 frames to HEIC")
        #expect(ProgressLine.encodeSummary(total: 1) == "encoded 1 frame to HEIC")
    }
}

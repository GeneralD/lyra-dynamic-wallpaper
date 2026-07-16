import Foundation
import Testing

@testable import LyraDynamicWallpaper

@Suite struct FrameTimelineTests {
    private func clip(start: Double, end: Double, scale: Double = 1) -> ResolvedClip {
        ResolvedClip(url: URL(fileURLWithPath: "/tmp/x.mp4"), start: start, end: end, scale: scale)
    }

    @Test func distributesEveryFrameExactlyOnce() {
        let clips = [clip(start: 0, end: 10), clip(start: 0, end: 30)] // durations 10, 30
        let result = FrameTimeline.distribute(clips: clips, frameCount: 400)

        let indices = result.flatMap { $0.map(\.index) }.sorted()
        #expect(indices == Array(0..<400))
    }

    @Test func splitsFramesProportionallyToTrimDuration() {
        let clips = [clip(start: 0, end: 10), clip(start: 0, end: 30)] // 25% / 75%
        let result = FrameTimeline.distribute(clips: clips, frameCount: 400)

        #expect((80...120).contains(result[0].count))
        #expect((280...320).contains(result[1].count))
    }

    @Test func samplesLandInsideEachTrimWindow() {
        let clips = [clip(start: 5, end: 15)]
        let result = FrameTimeline.distribute(clips: clips, frameCount: 10)

        #expect(result[0].allSatisfy { $0.time >= 5 && $0.time <= 15 })
    }

    @Test func daysFlowInConfigOrder() {
        let clips = [clip(start: 0, end: 10), clip(start: 0, end: 10)]
        let result = FrameTimeline.distribute(clips: clips, frameCount: 100)

        let firstMax = result[0].map(\.index).max() ?? -1
        let secondMin = result[1].map(\.index).min() ?? .max
        #expect(firstMax < secondMin)
    }

    @Test func emptyWhenNoDuration() {
        let clips = [clip(start: 5, end: 5)]
        let result = FrameTimeline.distribute(clips: clips, frameCount: 100)

        #expect(result[0].isEmpty)
    }
}

import AVFoundation
import Foundation
import Testing

@testable import LyraDynamicWallpaper

@Suite struct FrameExtractionTests {
    /// Regression: the callback resolves frames by the key of the echoed request
    /// `CMTime`. Keying the table on raw `Double` seconds instead of the
    /// quantized `CMTime` shifted keys by up to ±0.83 ms and silently dropped
    /// most frames (369/1440). Every requested time must hit the table.
    @Test func everyRequestedTimeResolvesInTheKeyTable() {
        // Fractional total durations akin to real footage make t*1000 land near
        // rounding boundaries — exactly where the old raw-seconds keys diverged.
        for total in [1004.037, 219.219, 1180.647] {
            let frames = 1440
            let samples = (0..<frames).map { k in
                FrameSample(index: k, time: (Double(k) + 0.5) / Double(frames) * total)
            }
            let (times, keyToIndex) = FrameExtraction.requestTable(for: samples)

            let resolved = times.filter { keyToIndex[FrameExtraction.key(for: $0.timeValue)] != nil }
            #expect(resolved.count == frames, "total=\(total): \(resolved.count)/\(frames) resolved")
        }
    }

    @Test func keyTableMapsBackToFrameIndices() {
        let samples = [FrameSample(index: 7, time: 1.2345), FrameSample(index: 9, time: 2.3456)]
        let (times, keyToIndex) = FrameExtraction.requestTable(for: samples)

        #expect(keyToIndex[FrameExtraction.key(for: times[0].timeValue)] == 7)
        #expect(keyToIndex[FrameExtraction.key(for: times[1].timeValue)] == 9)
    }
}

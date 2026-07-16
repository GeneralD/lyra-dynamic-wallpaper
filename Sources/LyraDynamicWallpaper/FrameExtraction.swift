import AVFoundation
import CoreGraphics
import Foundation

/// One requested frame: its global index in the day and its time in the source video.
struct FrameSample: Sendable {
    let index: Int
    let time: Double
}

/// Extracts and renders the frames assigned to a single clip.
enum FrameExtraction {
    /// Extract each `sample` from `clip`, apply the clip's scale/aspect rendering,
    /// and return `[globalIndex: renderedImage]`.
    static func render(clip: ResolvedClip, samples: [FrameSample], outputSize: CGSize) async -> [Int: CGImage] {
        guard !samples.isEmpty else { return [:] }

        let asset = AVURLAsset(url: clip.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let maximumSize = await decodeSize(for: asset, outputSize: outputSize, zoom: clip.scale) {
            generator.maximumSize = maximumSize
        }

        let times = samples.map { NSValue(time: CMTime(seconds: $0.time, preferredTimescale: 600)) }
        // uniquingKeysWith: absurd frame counts can place two samples within the
        // same millisecond — keep the first rather than trapping.
        let keyToIndex = Dictionary(samples.map { (msKey($0.time), $0.index) }, uniquingKeysWith: { first, _ in first })
        let collector = FrameCollector(remaining: samples.count)
        let scale = clip.scale

        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: times) { requestedTime, cgImage, _, status, error in
                var finished = false
                collector.lock.lock()
                if status == .succeeded, let cgImage,
                   let index = keyToIndex[msKey(CMTimeGetSeconds(requestedTime))],
                   let rendered = ImageProcessing.render(cgImage, to: outputSize, scale: scale) {
                    collector.images[index] = rendered
                } else if let error {
                    warn("frame at \(String(format: "%.2f", CMTimeGetSeconds(requestedTime)))s failed: \(error.localizedDescription)")
                }
                collector.remaining -= 1
                finished = collector.remaining == 0
                let images = finished ? collector.images : [:]
                collector.lock.unlock()
                if finished { continuation.resume(returning: images) }
            }
        }
    }

    /// Match a requested time back to its sample; the callback echoes the exact
    /// `CMTime` we requested, so a millisecond key round-trips reliably.
    private static func msKey(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }

    /// The smallest decode size that still fills the output after aspect-fill +
    /// center zoom — capping `AVAssetImageGenerator.maximumSize` so 4K sources
    /// aren't fully decoded 1440 times just to be shrunk afterwards. `nil`
    /// (decode at native size) when the track geometry can't be read.
    private static func decodeSize(for asset: AVURLAsset, outputSize: CGSize, zoom: Double) async -> CGSize? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (naturalSize, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return nil }

        let transformed = naturalSize.applying(transform)
        let sourceWidth = abs(transformed.width)
        let sourceHeight = abs(transformed.height)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        // Width of the source region that ends up on screen (aspect-fill crop,
        // then the central 1/zoom), mirroring ImageProcessing.render.
        let targetAspect = outputSize.width / outputSize.height
        let sourceAspect = sourceWidth / sourceHeight
        let cropWidth = sourceAspect > targetAspect ? sourceHeight * targetAspect : sourceWidth
        let regionWidth = cropWidth / CGFloat(max(1.0, zoom))

        let scale = min(1, outputSize.width / regionWidth)
        return CGSize(width: (sourceWidth * scale).rounded(.up) + 2, height: (sourceHeight * scale).rounded(.up) + 2)
    }
}

/// Lock-guarded accumulator shared with the (sendable) image-generator callback.
/// `@unchecked Sendable`: every access is serialized through `lock`, and `CGImage`
/// is safe to read across threads.
private final class FrameCollector: @unchecked Sendable {
    let lock = NSLock()
    var images: [Int: CGImage] = [:]
    var remaining: Int
    init(remaining: Int) { self.remaining = remaining }
}

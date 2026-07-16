import CoreGraphics
import Foundation

/// Maps a source video frame onto the wallpaper output the way lyra renders it:
/// aspect-fill into the target, then a center zoom by the item's `scale`.
enum ImageProcessing {
    /// Aspect-fill-crop `source` to the target aspect, apply a centered zoom of
    /// `scale`, and resize to exactly `size`. Mirrors lyra's
    /// `videoGravity = .resizeAspectFill` + `CGAffineTransform(scaleX: scale, …)`.
    static func render(_ source: CGImage, to size: CGSize, scale: Double) -> CGImage? {
        let sourceWidth = CGFloat(source.width)
        let sourceHeight = CGFloat(source.height)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let targetAspect = size.width / size.height
        let sourceAspect = sourceWidth / sourceHeight

        // Largest centered rect matching the output aspect (aspect-fill).
        var cropWidth: CGFloat
        var cropHeight: CGFloat
        if sourceAspect > targetAspect {
            cropHeight = sourceHeight
            cropWidth = sourceHeight * targetAspect
        } else {
            cropWidth = sourceWidth
            cropHeight = sourceWidth / targetAspect
        }

        // Zoom: keep the central 1/scale of that rect (macOS fills it back to full).
        let zoom = CGFloat(max(1.0, scale))
        cropWidth /= zoom
        cropHeight /= zoom

        let cropRect = CGRect(
            x: ((sourceWidth - cropWidth) / 2).rounded(),
            y: ((sourceHeight - cropHeight) / 2).rounded(),
            width: cropWidth.rounded(),
            height: cropHeight.rounded()
        )
        guard let cropped = source.cropping(to: cropRect) else { return nil }
        return resize(cropped, to: size)
    }

    /// Redraw `image` at exactly `size` with high-quality interpolation.
    static func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

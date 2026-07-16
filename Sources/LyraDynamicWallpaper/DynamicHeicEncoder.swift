import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes frames into a macOS Dynamic Desktop HEIC (`apple_desktop:h24`).
///
/// The `h24` metadata maps each frame to a fraction of the local 24h clock, so
/// macOS shows the frame nearest the current time of day (no Location Services,
/// unlike the `solar` schema). The metadata is attached to the first image only.
enum DynamicHeicEncoder {
    /// `onProgress`, if given, is called once per image added to the
    /// destination (in order) — disabled by default since encode is fast
    /// enough that most callers don't need per-frame feedback.
    static func write(images: [CGImage], to url: URL, quality: Double, onProgress: (@Sendable () -> Void)? = nil) throws {
        guard !images.isEmpty else { throw ToolError("no frames to encode") }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.heic.identifier as CFString, images.count, nil
        ) else {
            throw ToolError("cannot create HEIC destination at \(url.path)")
        }

        let frameOptions = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        for (index, image) in images.enumerated() {
            if index == 0 {
                let imageMetadata = try metadata(frameCount: images.count)
                CGImageDestinationAddImageAndMetadata(destination, image, imageMetadata, frameOptions)
            } else {
                CGImageDestinationAddImage(destination, image, frameOptions)
            }
            onProgress?()
        }

        guard CGImageDestinationFinalize(destination) else { throw ToolError("failed to write HEIC") }
    }

    /// The `apple_desktop:h24` tag: base64 of a binary plist
    /// `{ap:{l,d}, ti:[{i,t}]}` where `t` is 0…1 across the 24h day.
    private static func metadata(frameCount count: Int) throws -> CGMutableImageMetadata {
        let timeItems: [[String: Any]] = (0..<count).map { ["i": $0, "t": Double($0) / Double(count)] }
        let lightIndex = min(count - 1, Int((Double(count) * 0.5).rounded())) // ~noon
        let plist: [String: Any] = ["ap": ["l": lightIndex, "d": 0], "ti": timeItems]

        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) else {
            throw ToolError("failed to encode apple_desktop plist")
        }
        let base64 = data.base64EncodedString()

        let namespaceURI = "http://ns.apple.com/namespace/1.0/" as CFString
        let prefix = "apple_desktop" as CFString
        let metadata = CGImageMetadataCreateMutable()
        guard CGImageMetadataRegisterNamespaceForPrefix(metadata, namespaceURI, prefix, nil) else {
            throw ToolError("failed to register apple_desktop namespace")
        }
        guard let tag = CGImageMetadataTagCreate(namespaceURI, prefix, "h24" as CFString, .string, base64 as CFString),
              CGImageMetadataSetTagWithPath(metadata, nil, "apple_desktop:h24" as CFString, tag) else {
            throw ToolError("failed to attach apple_desktop:h24 metadata")
        }
        return metadata
    }
}

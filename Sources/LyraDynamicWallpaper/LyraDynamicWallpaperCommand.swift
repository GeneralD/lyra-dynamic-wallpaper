import ArgumentParser
import CoreGraphics
import Foundation

@main
struct LyraDynamicWallpaperCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lyra-dynamic-wallpaper",
        abstract: "Build a macOS Dynamic Desktop (.heic, apple_desktop:h24) from lyra's configured wallpaper videos.",
        discussion: """
        Reads lyra's [wallpaper] config, resolves every video (reusing lyra's cache
        via LyraKit), samples N frames across each item's trim range applying its
        per-item scale, and writes a time-of-day dynamic wallpaper. The desktop —
        and, by default, the lock screen — then shows the frame matching the local
        clock. More frames only make the time transition finer; it is never motion.
        """
    )

    @Option(name: [.customShort("n"), .long], help: "Number of frames mapped across the 24h day.")
    var frames: Int = 1440

    @Option(name: [.customShort("o"), .long], help: "Output .heic path (default: ~/Pictures/lyra-dynamic-wallpaper.heic).")
    var output: String?

    @Option(name: [.customShort("r"), .long], help: "Output size WxH.")
    var resize: String = "2560x1440"

    @Option(name: [.customShort("q"), .long], help: "HEIC quality 0<Q<=1.")
    var quality: Double = 0.7

    @Flag(help: "Set the generated HEIC as the desktop wallpaper (lock screen follows).")
    var apply = false

    func validate() throws {
        guard frames >= 2 else { throw ValidationError("--frames must be >= 2") }
        guard quality > 0, quality <= 1 else { throw ValidationError("--quality must be 0 < Q <= 1") }
        _ = try Self.parseSize(resize)
    }

    func run() async throws {
        let outputSize = try Self.parseSize(resize)
        let progress = ProgressReporter()
        // If any phase throws before reaching its `finished` call, this
        // terminates a dangling `\r`-anchored line so the thrown error's
        // message doesn't overwrite it from column 0 (see finalizeIfDangling).
        defer { progress.finalizeIfDangling() }
        // Routes any mid-phase warning through the same lock/cursor
        // discipline as the live progress line, so a skip/failure warning
        // (resolve's unresolvable-item skip, extract's per-frame failure)
        // can never land mid-line and corrupt it (see ProgressReporter.interject).
        let liveWarn: @Sendable (String) -> Void = { progress.interject(warningLine($0)) }

        progress.phaseStarted("resolving wallpapers …")
        let clips = try await WallpaperSource().resolveClips(warn: liveWarn)
        guard !clips.isEmpty else { throw ToolError("no usable wallpaper videos resolved from lyra config") }
        progress.resolveFinished(clipCount: clips.count)

        let perClipSamples = FrameTimeline.distribute(clips: clips, frameCount: frames)
        let totalFrames = perClipSamples.reduce(0) { $0 + $1.count }

        progress.phaseStarted("extracting frames …")
        let perClipImages = await clips.indices.asyncMap { index in
            await FrameExtraction.render(
                clip: clips[index], samples: perClipSamples[index], outputSize: outputSize,
                onProgress: { progress.extractFrameCompleted(total: totalFrames, clipIndex: index + 1, clipCount: clips.count) },
                warn: liveWarn
            )
        }
        let imagesByIndex = perClipImages.reduce(into: [Int: CGImage]()) { $0.merge($1) { current, _ in current } }

        let images = (0..<frames).compactMap { imagesByIndex[$0] }
        guard images.count == frames else {
            throw ToolError("extracted only \(images.count)/\(frames) frames — a source may be too short or unreadable")
        }
        // Only announce success once the completeness guard above has passed
        // — printing this unconditionally would show a success-shaped
        // summary immediately before the error on a short-extraction failure.
        progress.extractFinished(total: totalFrames, clipCount: clips.count)

        let outputURL = Self.resolveOutputURL(output)
        progress.phaseStarted("encoding HEIC …")
        try DynamicHeicEncoder.write(images: images, to: outputURL, quality: quality) {
            progress.encodeFrameCompleted(total: images.count)
        }
        progress.encodeFinished(total: images.count)
        report(outputURL: outputURL, clips: clips, dimensions: images[0])

        if apply {
            let failures = await DesktopWallpaperApplier.apply(outputURL)
            if failures.isEmpty {
                print("applied to desktop (lock screen follows unless separately customised).")
            } else {
                // Plain warn(), not liveWarn — every progress phase (including
                // encodeFinished above) has already finished by this point, so
                // no `\r`-anchored live line can be on screen to corrupt.
                warn("could not apply on: \(failures.joined(separator: ", "))")
            }
        }
    }

    // MARK: - Helpers

    private func report(outputURL: URL, clips: [ResolvedClip], dimensions: CGImage) {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? nil
        let sizeText = bytes.map { String(format: "%.1f MB", Double($0) / 1_048_576) } ?? "?"
        let totalTrim = clips.reduce(0) { $0 + $1.duration }
        print("wrote \(outputURL.path)")
        print("  \(frames) frames · \(dimensions.width)x\(dimensions.height) · \(sizeText) · quality \(quality)")
        print("  timeline: \(String(format: "%.1f", totalTrim))s across \(clips.count) clip(s)")
    }

    static func parseSize(_ string: String) throws -> CGSize {
        let parts = string.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else {
            throw ValidationError("--resize must be WxH, e.g. 2560x1440")
        }
        return CGSize(width: width, height: height)
    }

    static func resolveOutputURL(_ output: String?) -> URL {
        if let output {
            return URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures")
            .appendingPathComponent("lyra-dynamic-wallpaper.heic")
    }
}

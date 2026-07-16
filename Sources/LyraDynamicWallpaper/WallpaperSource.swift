import Dependencies
import Foundation
import LyraKit

/// A wallpaper video resolved to a local file, with its trim window and zoom.
///
/// `start`/`end` are seconds into the source video; `scale` mirrors lyra's
/// per-item wallpaper zoom (`>= 1.0`, applied on top of aspect-fill).
struct ResolvedClip: Sendable {
    let url: URL
    let start: Double
    let end: Double
    let scale: Double

    var duration: Double { end - start }
}

/// Reads lyra's configured wallpaper items through `LyraKit` and resolves each
/// `location` to a local cached file, reusing lyra's own config parsing and
/// YouTube/remote/cache pipeline (`@Dependency(\.configUseCase)` +
/// `@Dependency(\.wallpaperUseCase)`). No hashing/TOML logic is reimplemented here.
struct WallpaperSource {
    @Dependency(\.configUseCase) private var configUseCase
    @Dependency(\.wallpaperUseCase) private var wallpaperUseCase

    /// The configured items (in config order) plus the resolved config directory.
    func configuredItems() throws -> (items: [WallpaperItem], configDir: String) {
        let appStyle = configUseCase.appStyle
        guard let wallpaper = appStyle.wallpaper, !wallpaper.items.isEmpty else {
            throw ToolError("no wallpaper items in lyra config ([wallpaper] / [[wallpaper.items]])")
        }
        let configDir = appStyle.configDir ?? FileManager.default.homeDirectoryForCurrentUser.path
        return (wallpaper.items, configDir)
    }

    /// Resolve every configured item to a `ResolvedClip`, in config order.
    ///
    /// Unresolvable items (download failure, missing tool) are skipped with a
    /// warning rather than aborting the whole run.
    func resolveClips() async throws -> [ResolvedClip] {
        let (items, configDir) = try configuredItems()
        return try await items.asyncCompactMap { item in
            guard let url = try await resolve(item, configDir: configDir) else {
                warn("could not resolve \(item.location) — skipping")
                return nil
            }
            let duration = try await videoDuration(of: url)
            let start = max(0, item.start ?? 0)
            let end = min(duration, item.end ?? duration)
            guard end > start else {
                warn("empty trim range for \(item.location) — skipping")
                return nil
            }
            return ResolvedClip(url: url, start: start, end: end, scale: max(1.0, item.scale))
        }
    }

    private func resolve(_ item: WallpaperItem, configDir: String) async throws -> URL? {
        try await wallpaperUseCase.resolveWallpaper(value: item.location, configDir: configDir)
    }
}

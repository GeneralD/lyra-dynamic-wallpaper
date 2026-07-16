import AppKit
import Foundation

/// Sets the generated HEIC as the desktop wallpaper on every screen.
///
/// The lock screen follows the desktop wallpaper by default on macOS
/// (Sonoma+), so setting the desktop also reaches the lock screen unless the
/// user has customised it separately.
@MainActor
enum DesktopWallpaperApplier {
    /// Returns the screens that failed, if any.
    @discardableResult
    static func apply(_ url: URL) -> [String] {
        var failures: [String] = []
        for screen in NSScreen.screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            } catch {
                failures.append(screen.localizedName)
            }
        }
        return failures
    }
}

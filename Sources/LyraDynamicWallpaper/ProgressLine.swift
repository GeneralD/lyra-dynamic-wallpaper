import Foundation

/// Pure formatting for the single-line stderr progress display (resolve →
/// extract → encode). No I/O, no locking, no clocks — every function is a
/// plain `(state) -> String` transform, so it is unit-tested directly without
/// touching a terminal.
enum ProgressLine {
    /// Braille spinner glyphs, cycled by an ever-incrementing tick.
    static let spinnerFrames: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    /// The spinner glyph for `tick`, wrapping around `spinnerFrames`. Negative
    /// ticks wrap the same way (defensive — callers only ever pass `>= 0`).
    static func spinner(tick: Int) -> Character {
        let count = spinnerFrames.count
        let wrapped = ((tick % count) + count) % count
        return spinnerFrames[wrapped]
    }

    /// `[============>          ] 36%` — empty string when `total <= 0`
    /// (nothing meaningful to render, and avoids a division by zero).
    static func bar(completed: Int, total: Int, width: Int = 24) -> String {
        guard total > 0, width > 0 else { return "" }
        let fraction = min(1, max(0, Double(completed) / Double(total)))
        let filled = completed >= total ? width : Int((fraction * Double(width)).rounded(.down))
        let hasHead = filled > 0 && filled < width
        let head = hasHead ? ">" : ""
        let filledDashes = String(repeating: "=", count: max(0, filled - head.count))
        let empty = String(repeating: " ", count: max(0, width - filled))
        let percent = completed >= total ? 100 : Int((fraction * 100).rounded(.down))
        return "[\(filledDashes)\(head)\(empty)] \(percent)%"
    }

    /// `⠹ resolving wallpapers … 5/5 clips`
    static func resolve(tick: Int, resolved: Int, total: Int) -> String {
        "\(spinner(tick: tick)) resolving wallpapers … \(resolved)/\(total) clips"
    }

    /// `⠸ extracting frames … 512/1440 (clip 2/5)   [====>     ] 36%`
    static func extract(tick: Int, completed: Int, total: Int, clipIndex: Int, clipCount: Int) -> String {
        let barText = bar(completed: completed, total: total)
        let suffix = barText.isEmpty ? "" : "   \(barText)"
        return "\(spinner(tick: tick)) extracting frames … \(completed)/\(total) (clip \(clipIndex)/\(clipCount))\(suffix)"
    }

    /// `⠼ encoding HEIC … 1440/1440 frames`
    static func encode(tick: Int, completed: Int, total: Int) -> String {
        "\(spinner(tick: tick)) encoding HEIC … \(completed)/\(total) frames"
    }

    // MARK: - Phase-finished summaries
    //
    // No spinner glyph — a spinner implies ongoing motion, which is wrong on
    // the fixed line a phase leaves behind once it's done.

    static func resolveSummary(total: Int) -> String {
        "resolved \(total) clip\(total == 1 ? "" : "s")"
    }

    static func extractSummary(total: Int, clipCount: Int) -> String {
        "extracted \(total) frame\(total == 1 ? "" : "s") across \(clipCount) clip\(clipCount == 1 ? "" : "s")"
    }

    static func encodeSummary(total: Int) -> String {
        "encoded \(total) frame\(total == 1 ? "" : "s") to HEIC"
    }
}

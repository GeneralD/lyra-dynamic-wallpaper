import AVFoundation
import Foundation

/// A user-facing error whose message is printed verbatim by ArgumentParser.
struct ToolError: Error, CustomStringConvertible, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
    var errorDescription: String? { message }
}

/// Write a warning to stderr without aborting the run.
func warn(_ message: String) {
    FileHandle.standardError.write(Data("lyra-dynamic-wallpaper: warning: \(message)\n".utf8))
}

/// Total playable duration of a video, in seconds.
func videoDuration(of url: URL) async throws -> Double {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    let seconds = CMTimeGetSeconds(duration)
    guard seconds.isFinite, seconds > 0 else {
        throw ToolError("cannot read duration: \(url.lastPathComponent)")
    }
    return seconds
}

extension Sequence {
    /// `map` for an async, throwing transform. Preserves order; hides the `var`
    /// accumulator from call sites (see lyra's swift-idioms).
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self {
            result.append(try await transform(element))
        }
        return result
    }

    /// `compactMap` for an async, throwing transform. Preserves order.
    func asyncCompactMap<T>(_ transform: (Element) async throws -> T?) async rethrows -> [T] {
        var result: [T] = []
        for element in self {
            if let value = try await transform(element) { result.append(value) }
        }
        return result
    }
}

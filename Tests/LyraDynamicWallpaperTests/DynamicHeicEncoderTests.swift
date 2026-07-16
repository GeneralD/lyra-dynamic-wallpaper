import CoreGraphics
import Foundation
import Testing

@testable import LyraDynamicWallpaper

@Suite struct DynamicHeicEncoderTests {
    /// A tiny solid-color image — cheap to create and enough to exercise the
    /// encode path without needing real footage.
    private func tinyImage() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()!
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).heic")
    }

    @Test func onProgressFiresOnceForEveryImage() throws {
        let images = (0..<4).map { _ in tinyImage() }
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let counter = LockedCounter()
        try DynamicHeicEncoder.write(images: images, to: url, quality: 0.7) {
            counter.increment()
        }

        #expect(counter.value == 4)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func writeSucceedsWithoutAnOnProgressHook() throws {
        let images = (0..<2).map { _ in tinyImage() }
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try DynamicHeicEncoder.write(images: images, to: url, quality: 0.7)

        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

/// Lock-guarded counter for asserting how many times a `@Sendable` callback fired.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

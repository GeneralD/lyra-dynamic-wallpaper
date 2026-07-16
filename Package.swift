// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "lyra-dynamic-wallpaper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "lyra-dynamic-wallpaper", targets: ["LyraDynamicWallpaper"]),
    ],
    dependencies: [
        // Reuse lyra's config parsing + wallpaper cache/resolve pipeline via LyraKit
        // (the same library product lyra-screensaver consumes).
        .package(url: "https://github.com/GeneralD/lyra.git", from: "2.23.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "LyraDynamicWallpaper",
            dependencies: [
                .product(name: "LyraKit", package: "lyra"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Dependencies", package: "swift-dependencies"),
            ]
        ),
        .testTarget(
            name: "LyraDynamicWallpaperTests",
            dependencies: ["LyraDynamicWallpaper"]
        ),
    ]
)

// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DesktopWallpaper",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DesktopWallpaper", targets: ["DesktopWallpaper"])],
    targets: [
        .target(name: "WallpaperCore"),
        .executableTarget(name: "DesktopWallpaper", dependencies: ["WallpaperCore"]),
        .testTarget(name: "WallpaperCoreTests", dependencies: ["WallpaperCore", "DesktopWallpaper"])
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MusicVinyl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MusicVinyl",
            path: "Sources/MusicVinyl",
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])]
        )
    ]
)

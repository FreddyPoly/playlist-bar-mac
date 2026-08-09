// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PlaylistBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PlaylistBar",
            path: "Sources/PlaylistBar"
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitWall",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GitWall",
            path: "Sources/GitWall",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CodexTouchBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CodexTouchBar",
            path: "Sources/CodexTouchBar"
        ),
        .testTarget(
            name: "CodexTouchBarTests",
            dependencies: ["CodexTouchBar"],
            path: "Tests/CodexTouchBarTests"
        ),
    ]
)

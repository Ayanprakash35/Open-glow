// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenGlow",
    // The app needs macOS 26 (LSMinimumSystemVersion in Resources/Info.plist); .v14 suits older CI SDKs.
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenGlow",
            path: "Sources/OpenGlow"
        ),
        .testTarget(
            name: "OpenGlowTests",
            dependencies: ["OpenGlow"],
            path: "Tests/OpenGlowTests"
        ),
    ]
)

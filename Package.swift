// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenGlow",
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

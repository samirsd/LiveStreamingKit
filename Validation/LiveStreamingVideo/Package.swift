// swift-tools-version: 6.0
import PackageDescription

// Exercises the exact production sources without resolving audio-only dependencies.
let package = Package(
    name: "LiveVideoValidation",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [.library(name: "LiveStreamingVideo", targets: ["LiveStreamingVideo"])],
    targets: [
        .target(name: "LiveStreamingVideo"),
        .testTarget(name: "LiveStreamingVideoTests", dependencies: ["LiveStreamingVideo"])
    ]
)

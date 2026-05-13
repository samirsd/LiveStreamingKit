// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveStreamingKit",
    platforms: [
        .iOS("18.0"),
        .macOS("14.0")
    ],
    products: [
        .library(
            name: "LiveStreamingKit",
            targets: ["LiveStreamingKit"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "LiveStreamingKit",
            dependencies: []
        ),
        .testTarget(
            name: "LiveStreamingKitTests",
            dependencies: ["LiveStreamingKit"]
        ),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

// Run the exact production video sources without resolving audio-only packages.
let package = Package(
    name: "LiveVideoHTTPIntegration",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LiveVideoHTTPIntegration", targets: ["LiveVideoHTTPIntegration"])],
    targets: [
        .target(name: "LiveStreamingVideo"),
        .executableTarget(name: "LiveVideoHTTPIntegration", dependencies: ["LiveStreamingVideo"])
    ]
)

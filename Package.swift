// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let hasLocalAIMixKit = FileManager.default.fileExists(
    atPath: packageDirectory
        .appendingPathComponent("../AIMixKit/Package.swift")
        .standardizedFileURL.path
)
let useLocalDependencies =
    ProcessInfo.processInfo.environment["USE_LOCAL_PACKAGES"] == "1" ||
    hasLocalAIMixKit

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
    dependencies: [
        useLocalDependencies ?
            .package(path: "../AIMixKit") :
            .package(url: "https://github.com/samirsd/AIMixKit.git", from: "0.2.0"),
    ],
    targets: [
        .target(
            name: "LiveStreamingKit",
            dependencies: ["AIMixKit"]
        ),
        .testTarget(
            name: "LiveStreamingKitTests",
            dependencies: ["LiveStreamingKit"]
        ),
    ]
)

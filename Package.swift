// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let isLocalPackagesWorkspace = packageDirectory.deletingLastPathComponent().lastPathComponent == "packages"
let hasLocalAIMixKit = FileManager.default.fileExists(
    atPath: packageDirectory
        .appendingPathComponent("../AIMixKit/Package.swift")
        .standardizedFileURL.path
)
let hasLocalLoggingKit = FileManager.default.fileExists(
    atPath: packageDirectory
        .appendingPathComponent("../LoggingKit/Package.swift")
        .standardizedFileURL.path
)
let useLocalDependencies =
    ProcessInfo.processInfo.environment["USE_LOCAL_PACKAGES"] == "1" ||
    (isLocalPackagesWorkspace && hasLocalAIMixKit && hasLocalLoggingKit)

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
        useLocalDependencies ?
            .package(path: "../LoggingKit") :
            .package(url: "https://github.com/samirsd/LoggingKit.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "LiveStreamingKit",
            dependencies: ["AIMixKit", "LoggingKit"]
        ),
        .testTarget(
            name: "LiveStreamingKitTests",
            dependencies: ["LiveStreamingKit"]
        ),
    ]
)

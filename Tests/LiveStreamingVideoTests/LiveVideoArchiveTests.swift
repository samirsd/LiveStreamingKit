import Foundation
import XCTest
@testable import LiveStreamingVideo

final class LiveVideoArchiveTests: XCTestCase {
    private func temporaryParent() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        return parent
    }

    func testCreatesFreshDirectoriesAndNeverReplacesExistingUserFiles() throws {
        let parent = try temporaryParent()
        let sentinel = parent.appendingPathComponent("recording.mp4")
        try Data("keep me".utf8).write(to: sentinel)
        let a = try LiveVideoArchive(parentDirectory: parent, configuration: .init())
        let b = try LiveVideoArchive(parentDirectory: parent, configuration: .init())
        XCTAssertNotEqual(a.directoryURL, b.directoryURL)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep me".utf8))
    }

    func testPlaylistReferencesPersistedFragmentsAndRetainsFinalTail() throws {
        let archive = try LiveVideoArchive(parentDirectory: temporaryParent(), configuration: .init())
        let initialization = Data("ftyp-moov".utf8)
        let first = Data("moof-mdat-0".utf8)
        let tail = Data("moof-mdat-1".utf8)
        try archive.append(.init(kind: .initialization, sequence: 0, data: initialization))
        try archive.append(.init(kind: .media, sequence: 0, data: first, duration: 4.01))
        var playlist = try String(contentsOf: archive.playlistURL, encoding: .utf8)
        XCTAssertTrue(playlist.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        XCTAssertTrue(playlist.contains("#EXT-X-TARGETDURATION:5"))
        XCTAssertFalse(playlist.contains("ENDLIST"))
        try archive.append(.init(kind: .media, sequence: 1, data: tail, duration: 0.25))
        try archive.finish(success: true)
        try archive.finish(success: true)
        playlist = try String(contentsOf: archive.playlistURL, encoding: .utf8)
        XCTAssertTrue(playlist.contains("#EXTINF:0.250000,"))
        XCTAssertTrue(playlist.hasSuffix("#EXT-X-ENDLIST\n"))
        XCTAssertEqual(try Data(contentsOf: archive.directoryURL.appendingPathComponent("init.mp4")), initialization)
        XCTAssertEqual(try Data(contentsOf: archive.directoryURL.appendingPathComponent("segment-000001.m4s")), tail)
    }

    func testIncompleteRecordingDoesNotPretendArchiveCompleted() throws {
        let archive = try LiveVideoArchive(parentDirectory: temporaryParent(), configuration: .init())
        try archive.append(.init(kind: .initialization, sequence: 0, data: Data([1])))
        try archive.append(.init(kind: .media, sequence: 0, data: Data([2]), duration: 1))
        try archive.finish(success: false)
        XCTAssertFalse(try String(contentsOf: archive.playlistURL, encoding: .utf8).contains("ENDLIST"))
    }

    func testMissingDriveAndMissingSequenceAreExplicitErrors() throws {
        let parent = try temporaryParent()
        XCTAssertThrowsError(try LiveVideoArchive(parentDirectory: parent.appendingPathComponent("missing"), configuration: .init()))
        let archive = try LiveVideoArchive(parentDirectory: parent, configuration: .init())
        XCTAssertThrowsError(try archive.append(.init(kind: .media, sequence: 0, data: Data([1]), duration: 1)))
        try archive.append(.init(kind: .initialization, sequence: 0, data: Data([1])))
        XCTAssertThrowsError(try archive.append(.init(kind: .media, sequence: 1, data: Data([2]), duration: 1)))
        // Simulates a vanished selected directory without touching any real drive.
        try FileManager.default.removeItem(at: archive.directoryURL)
        XCTAssertThrowsError(try archive.append(.init(kind: .media, sequence: 0, data: Data([2]), duration: 1)))
    }

    func testInvalidConfigurationRejectsNonfiniteAndUnboundedInput() throws {
        for invalid in [Double.nan, Double.infinity, 0, 0.5, 100] {
            var configuration = LiveVideoConfiguration()
            configuration.segmentDuration = invalid
            XCTAssertThrowsError(try configuration.validate())
        }
        var configuration = LiveVideoConfiguration()
        configuration.maxPendingSamples = 0
        XCTAssertThrowsError(try configuration.validate())
        configuration = .init(videoWidth: 1919)
        XCTAssertThrowsError(try configuration.validate())
    }

    func testTargetDurationStaysFixedAndOversizedFragmentIsNotPublished() throws {
        let archive = try LiveVideoArchive(parentDirectory: temporaryParent(), configuration: .init())
        try archive.append(.init(kind: .initialization, sequence: 0, data: Data([1])))
        try archive.append(.init(kind: .media, sequence: 0, data: Data([2]), duration: 4))
        let first = try String(contentsOf: archive.playlistURL, encoding: .utf8)
        try archive.append(.init(kind: .media, sequence: 1, data: Data([3]), duration: 4.01))
        let second = try String(contentsOf: archive.playlistURL, encoding: .utf8)
        XCTAssertTrue(first.contains("#EXT-X-TARGETDURATION:5\n"))
        XCTAssertTrue(second.hasPrefix(first))
        XCTAssertThrowsError(try archive.append(.init(kind: .media, sequence: 2, data: Data([4]), duration: 6)))
        XCTAssertEqual(try String(contentsOf: archive.playlistURL, encoding: .utf8), second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.directoryURL.appendingPathComponent("segment-000002.m4s").path))
    }
}

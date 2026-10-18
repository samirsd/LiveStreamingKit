import Foundation
@preconcurrency import AVFoundation
import XCTest
@testable import LiveStreamingVideo

private final class BroadcasterEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LiveVideoEvent] = []
    func append(_ event: LiveVideoEvent) { lock.withLock { storage.append(event) } }
    var values: [LiveVideoEvent] { lock.withLock { storage } }
}

private actor UnavailableVideoSink: LiveVideoSegmentSink {
    func send(_ segment: LiveVideoSegment) async throws { throw URLError(.notConnectedToInternet) }
}

private actor SuspendedVideoSink: LiveVideoSegmentSink {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func send(_ segment: LiveVideoSegment) async throws {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

final class LiveVideoBroadcasterTests: XCTestCase, @unchecked Sendable {
    private func temporaryParent() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        return parent
    }

    private func makeBroadcaster(sink: (any LiveVideoSegmentSink)? = nil, events: BroadcasterEvents) throws -> LiveVideoBroadcaster {
        try LiveVideoBroadcaster(
            configuration: .init(videoWidth: 160, videoHeight: 96, framesPerSecond: 15, videoBitrate: 200_000, segmentDuration: 1),
            archiveParentDirectory: temporaryParent(), sink: sink, onEvent: events.append
        )
    }

    private func feed(_ broadcaster: LiveVideoBroadcaster, seconds: Double = 1.25) async throws {
        let epoch = CMTime(seconds: 100, preferredTimescale: 48_000)
        try broadcaster.start(at: epoch)
        var audioFrame = 0
        for videoFrame in 0..<Int(seconds * 15) {
            let video = try FragmentedMP4Fixtures.video(frame: videoFrame)
            _ = broadcaster.appendVideo(video, at: epoch + CMSampleBufferGetPresentationTimeStamp(video))
            let nextVideoTime = Double(videoFrame + 1) / 15
            while Double(audioFrame) / 48_000 < nextVideoTime {
                let audio = try FragmentedMP4Fixtures.audio(firstFrame: audioFrame)
                _ = broadcaster.appendAudio(audio, at: epoch + CMSampleBufferGetPresentationTimeStamp(audio))
                audioFrame += 1024
            }
            // Feed a bounded live cadence, rather than flood an offline encoder.
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testNetworkFailureDoesNotInterruptLocalMovieAndRepeatedStopIsSafe() async throws {
        let events = BroadcasterEvents()
        let broadcaster = try makeBroadcaster(sink: UnavailableVideoSink(), events: events)
        try await feed(broadcaster)
        try await broadcaster.stop()
        try await broadcaster.stop()
        XCTAssertEqual(broadcaster.state, .finished)
        XCTAssertNotNil(broadcaster.deliveryError)
        // Concatenation is only a decoder probe. The canonical saved output is
        // the HLS bundle; its per-track timestamps preserve alignment offsets.
        let directory = try XCTUnwrap(broadcaster.archiveDirectoryURL)
        let probeURL = directory.appendingPathComponent("decoder-probe.mp4")
        let parts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let media = parts.filter { $0.pathExtension == "m4s" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var bytes = try Data(contentsOf: directory.appendingPathComponent("init.mp4"))
        for url in media { bytes.append(try Data(contentsOf: url)) }
        try bytes.write(to: probeURL)
        let asset = AVURLAsset(url: probeURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 1)
        let playlist = try String(contentsOf: XCTUnwrap(broadcaster.archivePlaylistURL), encoding: .utf8)
        XCTAssertTrue(playlist.hasSuffix("#EXT-X-ENDLIST\n"))
        XCTAssertTrue(events.values.contains { if case .deliveryFailed = $0 { return true }; return false })
    }

    func testLostArchiveIsReportedAndStopDoesNotClaimSuccessfulSave() async throws {
        let events = BroadcasterEvents()
        let broadcaster = try makeBroadcaster(events: events)
        // Remove only this test's newly created owned session directory.
        try FileManager.default.removeItem(at: XCTUnwrap(broadcaster.archiveDirectoryURL))
        try await feed(broadcaster)
        do {
            try await broadcaster.stop()
            XCTFail("A missing drive must not report a successful recording")
        } catch {
            guard case .archiveFailed = error as? LiveVideoError else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertNotNil(broadcaster.archiveError)
        XCTAssertTrue(events.values.contains { if case .archiveFailed = $0 { return true }; return false })
    }

    func testMissingDestinationsAndRestartAreRejected() async throws {
        XCTAssertThrowsError(try LiveVideoBroadcaster())
        let events = BroadcasterEvents()
        let broadcaster = try makeBroadcaster(events: events)
        try await feed(broadcaster)
        try await broadcaster.stop(drainDelivery: false)
        XCTAssertThrowsError(try broadcaster.start())
    }

    func testLaterStopCanCancelAnEarlierBlockedNetworkDrain() async throws {
        let sink = SuspendedVideoSink()
        let events = BroadcasterEvents()
        let broadcaster = try makeBroadcaster(sink: sink, events: events)
        try await feed(broadcaster)
        for _ in 0..<500 {
            if await sink.entered { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let entered = await sink.entered
        XCTAssertTrue(entered)
        let firstDone = expectation(description: "initial network drain released")
        let secondDone = expectation(description: "cancelling stop finished local recording")
        Task {
            do { try await broadcaster.stop(); firstDone.fulfill() }
            catch { firstDone.fulfill(); XCTFail("\(error)") }
        }
        for _ in 0..<500 {
            if broadcaster.state == .stopping { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(broadcaster.state, .stopping)
        Task {
            do { try await broadcaster.stop(drainDelivery: false); secondDone.fulfill() }
            catch { secondDone.fulfill(); XCTFail("\(error)") }
        }
        await fulfillment(of: [firstDone, secondDone], timeout: 2)
        await sink.release()
        XCTAssertEqual(broadcaster.state, .finished)
    }

    func testSinkOnlyFailureDoesNotClaimSuccessfulBroadcast() async throws {
        let broadcaster = try LiveVideoBroadcaster(
            configuration: .init(videoWidth: 160, videoHeight: 96, framesPerSecond: 15, videoBitrate: 200_000, segmentDuration: 1),
            sink: UnavailableVideoSink()
        )
        try await feed(broadcaster)
        do {
            try await broadcaster.stop()
            XCTFail("There is no successful destination after a sink-only failure")
        } catch {
            guard case .deliveryFailed = error as? LiveVideoError else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertNotNil(broadcaster.deliveryError)
    }

    func testLossOfBothDestinationsFailsTheTake() async throws {
        let events = BroadcasterEvents()
        let broadcaster = try makeBroadcaster(sink: UnavailableVideoSink(), events: events)
        try FileManager.default.removeItem(at: XCTUnwrap(broadcaster.archiveDirectoryURL))
        try await feed(broadcaster)
        do { try await broadcaster.stop(); XCTFail("Both destinations failed") } catch {}
        XCTAssertNotNil(broadcaster.archiveError)
        XCTAssertNotNil(broadcaster.deliveryError)
        guard case .failed = broadcaster.state else { return XCTFail("No destination remains") }
    }
}

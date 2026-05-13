import XCTest
import AVFoundation
@testable import LiveStreamingKit

final class LiveStreamEngineTests: XCTestCase {
    private let sampleRate: Double = 48_000

    func testStartCreatesSessionAndTransitionsToLive() async throws {
        let transport = MockTransport()
        await transport.queueJSON(
            CreateSessionResponse(
                id: "live-1",
                ingest_token: "tok",
                ingest_url: "https://example.com/api/v1/livestream/sessions/live-1/segments/",
                listener_url: "https://example.com/live/live-1/master.m3u8",
                master_playlist_url: "https://example.com/live/live-1/master.m3u8"
            ),
            statusCode: 201
        )
        let collector = EventCollector()
        let config = LiveStreamConfig(
            ingestBaseURL: URL(string: "https://example.com")!,
            authTokenProvider: { "auth" }
        )
        let engine = LiveStreamEngine(config: config, transport: transport) { collector.append($0) }

        let session = try await engine.start()
        XCTAssertEqual(session.id, "live-1")
        switch engine.liveState {
        case .live(let liveSession, _):
            XCTAssertEqual(liveSession.id, "live-1")
        default:
            XCTFail("expected live state, got \(engine.liveState)")
        }
        let events = await collector.snapshot()
        let transitions = events.compactMap { event -> LiveStreamState? in
            if case .stateChanged(let state) = event { return state } else { return nil }
        }
        XCTAssertEqual(transitions.first, .preparing)
        XCTAssertNotNil(transitions.first { if case .live = $0 { return true }; return false })
    }

    func testStartFailsWhenBackendRejects() async {
        let transport = MockTransport()
        await transport.queueEmpty(statusCode: 500)
        let config = LiveStreamConfig(
            ingestBaseURL: URL(string: "https://example.com")!,
            authTokenProvider: { "auth" }
        )
        let collector = EventCollector()
        let engine = LiveStreamEngine(config: config, transport: transport) { collector.append($0) }
        do {
            _ = try await engine.start()
            XCTFail("expected failure")
        } catch {
            // expected
        }
        if case .failed = engine.liveState {
            // ok
        } else {
            XCTFail("expected failed state, got \(engine.liveState)")
        }
    }

    func testObserveBufferEmitsSegmentEventsOnceLive() async throws {
        let transport = MockTransport()
        await transport.queueJSON(
            CreateSessionResponse(
                id: "live-2",
                ingest_token: "tok",
                ingest_url: "https://example.com/api/v1/livestream/sessions/live-2/segments/",
                listener_url: "https://example.com/live/live-2/master.m3u8",
                master_playlist_url: "https://example.com/live/live-2/master.m3u8"
            ),
            statusCode: 201
        )
        // Queue several 204 segment uploads
        for _ in 0..<8 { await transport.queueEmpty(statusCode: 204) }
        await transport.queueEmpty(statusCode: 204) // for endSession

        let collector = EventCollector()
        let config = LiveStreamConfig(
            ingestBaseURL: URL(string: "https://example.com")!,
            authTokenProvider: { "auth" },
            sampleRate: sampleRate,
            segmentDuration: 0.2 // small segments for fast test
        )
        let engine = LiveStreamEngine(config: config, transport: transport) { collector.append($0) }
        _ = try await engine.start()

        // Feed 1 second of stereo float audio in 1024-frame slices.
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false))
        let totalSlices = Int(sampleRate) / 1024 + 1
        for slice in 0..<totalSlices {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
            buffer.frameLength = 1024
            if let data = buffer.floatChannelData {
                for n in 0..<1024 {
                    let v = Float(sin(2.0 * .pi * 440.0 * Double(slice * 1024 + n) / sampleRate)) * 0.3
                    data[0][n] = v
                    data[1][n] = v
                }
            }
            engine.observe(buffer: buffer, at: AVAudioFramePosition(slice * 1024))
        }

        // Give the engine queue a moment to flush.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        await engine.stop()
        let events = await collector.snapshot()
        let encoded = events.filter {
            if case .segmentEncoded = $0 { return true }; return false
        }
        XCTAssertGreaterThan(encoded.count, 0, "expected at least one encoded segment event")
    }
}

import XCTest
import AVFoundation
@testable import LiveStreamingKit

final class LiveStreamEngineStateTests: XCTestCase {
    private let sampleRate: Double = 48_000

    func testInitialStateIsIdle() {
        let transport = MockTransport()
        let engine = LiveStreamEngine(config: defaultConfig(), transport: transport) { _ in }
        XCTAssertEqual(engine.liveState, .idle)
        XCTAssertNil(engine.currentSession)
    }

    func testStartFailsWithNotAuthenticatedWhenTokenIsNil() async {
        let transport = MockTransport()
        let config = LiveStreamConfig(
            ingestBaseURL: URL(string: "https://example.com")!,
            authTokenProvider: { nil }
        )
        let engine = LiveStreamEngine(config: config, transport: transport) { _ in }
        do {
            _ = try await engine.start()
            XCTFail("expected error")
        } catch let error as LiveStreamError {
            XCTAssertEqual(error, .notAuthenticated)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        if case .failed = engine.liveState { /* ok */ } else {
            XCTFail("expected .failed state, got \(engine.liveState)")
        }
    }

    func testDoubleStartThrowsSessionAlreadyStarted() async throws {
        let transport = MockTransport()
        await transport.queueJSON(makeCreateResponse(id: "s1"), statusCode: 201)
        let engine = LiveStreamEngine(config: defaultConfig(), transport: transport) { _ in }
        _ = try await engine.start()
        do {
            _ = try await engine.start()
            XCTFail("expected error")
        } catch let error as LiveStreamError {
            XCTAssertEqual(error, .sessionAlreadyStarted)
        }
    }

    func testStopFromIdleIsHarmless() async {
        let transport = MockTransport()
        let engine = LiveStreamEngine(config: defaultConfig(), transport: transport) { _ in }
        await engine.stop()
        // Still idle (not transitioned to .stopped because no start happened)
        XCTAssertEqual(engine.liveState, .idle)
    }

    func testFailedThenStartAgainSucceeds() async throws {
        let transport = MockTransport()
        await transport.queueEmpty(statusCode: 500)
        await transport.queueJSON(makeCreateResponse(id: "s2"), statusCode: 201)
        let engine = LiveStreamEngine(config: defaultConfig(), transport: transport) { _ in }
        do { _ = try await engine.start() } catch { /* expected */ }
        if case .failed = engine.liveState { /* ok */ } else {
            XCTFail("expected .failed, got \(engine.liveState)")
        }
        let session = try await engine.start()
        XCTAssertEqual(session.id, "s2")
    }

    func testStopAfterLiveTransitionsToStopped() async throws {
        let transport = MockTransport()
        await transport.queueJSON(makeCreateResponse(id: "s3"), statusCode: 201)
        await transport.queueEmpty(statusCode: 204) // endSession
        let engine = LiveStreamEngine(config: defaultConfig(), transport: transport) { _ in }
        _ = try await engine.start()
        await engine.stop()
        if case .stopped(let reason) = engine.liveState {
            XCTAssertEqual(reason, .requested)
        } else {
            XCTFail("expected .stopped, got \(engine.liveState)")
        }
    }

    func testStopWithExplicitReasonPropagates() async throws {
        let transport = MockTransport()
        await transport.queueJSON(makeCreateResponse(id: "s4"), statusCode: 201)
        await transport.queueEmpty(statusCode: 204)
        let engine = LiveStreamEngine(config: defaultConfig(), transport: transport) { _ in }
        _ = try await engine.start()
        await engine.stop(reason: .recordingEnded)
        if case .stopped(let reason) = engine.liveState {
            XCTAssertEqual(reason, .recordingEnded)
        } else {
            XCTFail("expected .stopped, got \(engine.liveState)")
        }
    }

    func testObserveBufferBeforeStartIsIgnored() throws {
        let transport = MockTransport()
        let collector = EventCollector()
        let engine = LiveStreamEngine(config: defaultConfig(), transport: transport) { collector.append($0) }
        let buffer = try makeStereoBuffer()
        engine.observe(buffer: buffer, at: 0)
        // give the async queue a moment
        let exp = expectation(description: "no events")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        let events = collector.snapshot()
        XCTAssertTrue(events.allSatisfy {
            if case .segmentEncoded = $0 { return false }
            return true
        })
    }

    func testStateChangedEventsFireOnEachTransition() async throws {
        let transport = MockTransport()
        await transport.queueJSON(makeCreateResponse(id: "s5"), statusCode: 201)
        await transport.queueEmpty(statusCode: 204)
        let collector = EventCollector()
        let engine = LiveStreamEngine(config: defaultConfig(), transport: transport) { collector.append($0) }
        _ = try await engine.start()
        await engine.stop()
        let transitions = collector.snapshot().compactMap { event -> LiveStreamState? in
            if case .stateChanged(let state) = event { return state }
            return nil
        }
        // We expect at least: preparing → live → stopping → stopped
        XCTAssertGreaterThanOrEqual(transitions.count, 4)
        XCTAssertEqual(transitions.first, .preparing)
        XCTAssertEqual(transitions.last, .stopped(reason: .requested))
    }

    // MARK: - Helpers

    private func defaultConfig() -> LiveStreamConfig {
        LiveStreamConfig(
            ingestBaseURL: URL(string: "https://example.com")!,
            authTokenProvider: { "tok" }
        )
    }

    private func makeCreateResponse(id: String) -> CreateSessionResponse {
        CreateSessionResponse(
            id: id,
            ingest_token: "tok",
            ingest_url: "https://example.com/api/v1/livestream/sessions/\(id)/segments/",
            listener_url: "https://example.com/live/\(id)/master.m3u8",
            master_playlist_url: "https://example.com/live/\(id)/master.m3u8"
        )
    }

    private func makeStereoBuffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        return buffer
    }
}

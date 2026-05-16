import XCTest
@testable import LiveStreamingKit

/// Verifies that HTTP requests built by `LiveStreamClient` honor the
/// `LiveStreamConfig.requestTimeout`. Without this, a wedged backend (e.g. a
/// dead ngrok tunnel) leaves the broadcaster UI stuck on "preparing stream"
/// for `URLSession`'s default 60s timeout instead of failing fast.
final class LiveStreamClientTimeoutTests: XCTestCase {

    func testCreateSessionRequestAppliesConfiguredTimeout() async throws {
        let transport = MockTransport()
        await transport.queueJSON(
            CreateSessionResponse(
                id: "session-1",
                ingest_token: "tok",
                ingest_url: "https://example.com/ingest",
                listener_url: "https://example.com/listen",
                master_playlist_url: "https://example.com/master.m3u8"
            ),
            statusCode: 201
        )
        let config = LiveStreamConfig(
            ingestBaseURL: URL(string: "https://example.com")!,
            authTokenProvider: { "test-token" },
            requestTimeout: 7
        )
        let client = LiveStreamClient(config: config, transport: transport)
        _ = try await client.createSession()
        let captured = await transport.captured
        XCTAssertEqual(captured.first?.timeoutInterval ?? 0, 7, accuracy: 0.001,
                       "createSession URLRequest must inherit LiveStreamConfig.requestTimeout")
    }

    func testDefaultTimeoutIsSensibleForInteractiveUI() {
        let config = LiveStreamConfig(
            ingestBaseURL: URL(string: "https://example.com")!,
            authTokenProvider: { nil }
        )
        // Defaults to something < URLSession's 60s default so a stuck request
        // surfaces in the UI within a reasonable time. 15s is the agreed bar.
        XCTAssertLessThanOrEqual(config.requestTimeout, 30)
        XCTAssertGreaterThan(config.requestTimeout, 0)
    }
}

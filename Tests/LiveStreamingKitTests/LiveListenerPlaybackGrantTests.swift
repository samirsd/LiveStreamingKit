import XCTest
@testable import LiveStreamingKit

final class LiveListenerPlaybackGrantTests: XCTestCase {
    func testAuthenticatedGrantPreservesScopedURLAndUsesConfiguredTimeout() async throws {
        let transport = MockTransport()
        let url = "https://example.test/live/session/master.m3u8?playback_token=bounded-grant"
        await transport.queueJSON(response(url: url), statusCode: 200)
        let grant = try await client(transport).fetchPlaybackGrant(sessionID: "session")
        XCTAssertEqual(grant.masterPlaylistURL.absoluteString, url)
        XCTAssertGreaterThan(grant.expiresAt, Date())
        let requests = await transport.captured
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://example.test/api/v1/livestream/sessions/session/playback/")
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer account-token")
        XCTAssertEqual(requests[0].timeoutInterval, 7)
    }

    func testMissingAuthenticationNeverRequestsGrant() async {
        let transport = MockTransport()
        await assertError(.authenticationRequired) {
            try await self.client(transport, token: nil).fetchPlaybackGrant(sessionID: "session")
        }
        let requests = await transport.captured
        XCTAssertTrue(requests.isEmpty)
    }

    func testServerDenialsDistinguishSignInFromSubscription() async {
        let transport = MockTransport()
        await transport.queueEmpty(statusCode: 401)
        await assertError(.authenticationRequired) { try await self.client(transport).fetchPlaybackGrant(sessionID: "session") }
        await transport.queueJSON(["code": "subscription_required"], statusCode: 403)
        await assertError(.subscriptionRequired) { try await self.client(transport).fetchPlaybackGrant(sessionID: "session") }
        await transport.queueJSON(["code": "different_failure"], statusCode: 403)
        await assertError(.unavailable) { try await self.client(transport).fetchPlaybackGrant(sessionID: "session") }
    }

    func testRejectsUntrustedOriginWrongSessionUnsignedAndExpiredGrants() async {
        for url in [
            "https://other.test/live/session/master.m3u8?playback_token=grant",
            "http://example.test/live/session/master.m3u8?playback_token=grant",
            "https://example.test/live/different/master.m3u8?playback_token=grant",
            "https://example.test/live/session/master.m3u8"
        ] {
            let transport = MockTransport()
            await transport.queueJSON(response(url: url), statusCode: 200)
            await assertError(.invalidResponse) { try await self.client(transport).fetchPlaybackGrant(sessionID: "session") }
        }
        let transport = MockTransport()
        await transport.queueJSON(response(
            url: "https://example.test/live/session/master.m3u8?playback_token=grant",
            expires: "2000-01-01T00:00:00Z"
        ), statusCode: 200)
        await assertError(.invalidResponse) { try await self.client(transport).fetchPlaybackGrant(sessionID: "session") }
    }

    func testBroadcaster403PreservesSubscriptionCodeForAppRecovery() async throws {
        let transport = MockTransport()
        await transport.queueJSON(["code": "subscription_required"], statusCode: 403)
        do {
            _ = try await client(transport).createSession()
            XCTFail("Expected subscription rejection")
        } catch let LiveStreamError.backendRejected(statusCode, body) {
            XCTAssertEqual(statusCode, 403)
            XCTAssertTrue(body?.contains("subscription_required") == true)
        } catch { XCTFail("Wrong broadcaster failure: \(error)") }
    }

    private struct Response: Encodable {
        let master_playlist_url: String
        let expires_at: String
        let expires_in: Int
    }

    private func response(url: String, expires: String = "2099-01-01T00:00:00.000Z") -> Response {
        Response(master_playlist_url: url, expires_at: expires, expires_in: 43200)
    }

    private func client(_ transport: MockTransport, token: String? = "account-token") -> LiveStreamClient {
        LiveStreamClient(config: LiveStreamConfig(
            ingestBaseURL: URL(string: "https://example.test/")!, authTokenProvider: { token }, requestTimeout: 7
        ), transport: transport)
    }

    private func assertError(
        _ expected: LiveListenerAccessError,
        action: () async throws -> LiveListenerPlaybackGrant
    ) async {
        do { _ = try await action(); XCTFail("Expected access rejection") }
        catch let error as LiveListenerAccessError { XCTAssertEqual(error, expected) }
        catch { XCTFail("Unexpected failure: \(error)") }
    }
}

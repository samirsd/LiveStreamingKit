import Foundation
import CryptoKit
import XCTest
@testable import LiveStreamingVideo

private actor VideoHTTPFixture: LiveVideoHTTPTransport {
    struct Reply: Sendable {
        let status: Int
        let body: String
        init(_ status: Int = 200, _ body: String = "{}") { self.status = status; self.body = body }
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        return (Data(reply.body.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                                     httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}

final class LiveVideoHTTPClientTests: XCTestCase, @unchecked Sendable {
    private let supported = "{\"video\":{\"enabled\":true,\"protocol\":\"h264-aac-fmp4-v1\",\"delivery\":\"direct-upload-v1\"}}"
    private let created = "{\"id\":\"abc-123\",\"ingest_token\":\"ingest-secret\",\"upload_authorization_url\":\"/api/v1/livestream/sessions/abc-123/uploads/\",\"listener_url\":\"https://carnyx.app/live/abc-123\",\"master_playlist_url\":\"/live/abc-123/master.m3u8\"}"

    private func grant(upload: String = "https://storage.example/private/segment.m4s?signature=secret",
                       commit: String = "/api/v1/livestream/sessions/abc-123/uploads/upload-1/commit/",
                       headers: [String: String] = ["Content-Type": "video/mp4", "x-goog-if-generation-match": "0"]) throws -> String {
        let object: [String: Any] = ["upload_id": "upload-1", "upload_url": upload,
                                    "commit_url": commit, "method": "PUT", "headers": headers]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func client(_ transport: VideoHTTPFixture, token: String? = "account-secret") -> LiveVideoHTTPClient {
        LiveVideoHTTPClient(configuration: .init(baseURL: URL(string: "https://api.example/")!,
                                                authToken: { token }), transport: transport)
    }

    private func session() -> LiveVideoHTTPSession {
        .init(id: "abc-123", ingestToken: "ingest-secret",
              uploadAuthorizationURL: URL(string: "https://api.example/api/v1/livestream/sessions/abc-123/uploads/")!,
              listenerURL: URL(string: "https://carnyx.app/live/abc-123")!,
              masterPlaylistURL: URL(string: "https://api.example/live/abc-123/master.m3u8")!)
    }

    func testCapabilityFailsClosedForAudioOnlyOrLegacyVideoServer() async throws {
        for response in ["{\"video\":{\"enabled\":false}}",
                         "{\"video\":{\"enabled\":true,\"protocol\":\"h264-aac-fmp4-v1\"}}"] {
            let fixture = VideoHTTPFixture([.init(200, response)])
            let supported = try await client(fixture).isSupported()
            XCTAssertFalse(supported)
            let requests = await fixture.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testCreateRequestsPortraitAndRequiresExplicitDirectDeliveryCapability() async throws {
        let fixture = VideoHTTPFixture([.init(200, supported), .init(201, created)])
        let video = LiveVideoConfiguration(videoWidth: 720, videoHeight: 1280, segmentDuration: 2)
        let result = try await client(fixture).createSession(video: video, title: "venue")
        XCTAssertEqual(result.id, "abc-123")
        let requests = await fixture.requests
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer account-secret")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[1].httpBody)) as? [String: Any])
        XCTAssertEqual(body["codec"] as? String, "h264-aac-fmp4")
        XCTAssertEqual(body["video_height"] as? Int, 1280)
        XCTAssertEqual(body["segment_duration_seconds"] as? Int, 2)
    }

    func testCreateRequiresAuthenticationAndNeverRetriesCreation() async throws {
        let unauthenticated = VideoHTTPFixture([.init(200, supported)])
        do {
            _ = try await client(unauthenticated, token: nil).createSession(video: .init())
            XCTFail("Creation must require an account")
        } catch { XCTAssertEqual(error as? LiveVideoHTTPError, .notAuthenticated) }
        let transient = VideoHTTPFixture([.init(200, supported), .init(503)])
        do { _ = try await client(transient).createSession(video: .init()); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? LiveVideoHTTPError, .rejected(statusCode: 503)) }
        let requests = await transient.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testUploadSendsOnlySignedHeadersToStorageAndCommitsBeforeAcknowledging() async throws {
        let fixture = VideoHTTPFixture([.init(200, try grant()), .init(200), .init(201)])
        let data = Data("encoded-fragment".utf8)
        try await client(fixture).sink(for: session()).send(.init(kind: .media, sequence: 0, data: data, duration: 2))
        let requests = await fixture.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "PUT", "POST"])
        XCTAssertEqual(requests[1].url?.host, "storage.example")
        XCTAssertEqual(requests[1].httpBody, data)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "x-goog-if-generation-match"), "0")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "X-Ingest-Token"))
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(requests[1].httpShouldHandleCookies)
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "X-Ingest-Token"), "ingest-secret")
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        XCTAssertEqual(metadata["sha256"] as? String, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(metadata["bytes"] as? Int, data.count)
    }

    func testLostAcknowledgementPreconditionFailureStillRequiresVerifiedCommit() async throws {
        let fixture = VideoHTTPFixture([.init(200, try grant()), .init(412), .init(200)])
        try await client(fixture).sink(for: session()).send(.init(kind: .initialization, sequence: 0, data: Data([1])))
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests[2].url!.path.hasSuffix("/commit"))
    }

    func testConflictDoesNotRetryOrOverwriteMedia() async throws {
        let fixture = VideoHTTPFixture([.init(200, try grant()), .init(412), .init(409)])
        do {
            try await client(fixture).sink(for: session()).send(.init(kind: .initialization, sequence: 0, data: Data([1])))
            XCTFail("Conflicting immutable content must fail")
        } catch { XCTAssertEqual(error as? LiveVideoHTTPError, .rejected(statusCode: 409)) }
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testTransientCommitFailureReauthorizesSameBytesAndReconcilesExistingObject() async throws {
        let fixture = VideoHTTPFixture([.init(200, try grant()), .init(200), .init(503),
                                       .init(200, try grant()), .init(412), .init(200)])
        try await client(fixture).sink(for: session()).send(.init(kind: .initialization, sequence: 0, data: Data([1])))
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(requests[0].httpBody, requests[3].httpBody)
        XCTAssertEqual(requests[1].httpBody, requests[4].httpBody)
    }

    func testExpiredStorageGrantIsReplacedButForbiddenControlGrantIsNotRetried() async throws {
        let expired = VideoHTTPFixture([.init(200, try grant()), .init(403),
                                       .init(200, try grant()), .init(200), .init(201)])
        try await client(expired).sink(for: session()).send(.init(kind: .initialization, sequence: 0, data: Data([1])))
        let forbidden = VideoHTTPFixture([.init(403)])
        do {
            try await client(forbidden).sink(for: session()).send(.init(kind: .initialization, sequence: 0, data: Data([1])))
            XCTFail("Revoked control permission must fail")
        } catch { XCTAssertEqual(error as? LiveVideoHTTPError, .rejected(statusCode: 403)) }
        let requests = await forbidden.requests
        XCTAssertEqual(requests.count, 1)
    }

    private let expiredStorageXML = "<?xml version='1.0' encoding='UTF-8'?><Error><Code>ExpiredToken</Code><Message>Request has expired</Message></Error>"

    func testGCSExpiredToken400ReauthorizesSameBytesAndCompletesVerifiedCommit() async throws {
        let fixture = VideoHTTPFixture([.init(200, try grant()), .init(400, expiredStorageXML),
                                       .init(200, try grant(upload: "https://storage.example/private/segment.m4s?signature=renewed")),
                                       .init(200), .init(201)])
        let data = Data("retained-fragment".utf8)
        try await client(fixture).sink(for: session()).send(.init(kind: .media, sequence: 0, data: data, duration: 2))
        let requests = await fixture.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "PUT", "POST", "PUT", "POST"])
        XCTAssertEqual(requests[0].httpBody, requests[2].httpBody)
        XCTAssertEqual(requests[1].httpBody, requests[3].httpBody)
        XCTAssertNotEqual(requests[1].url, requests[3].url)
        XCTAssertNil(requests[3].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests[3].value(forHTTPHeaderField: "X-Ingest-Token"))
        XCTAssertTrue(requests[4].url!.path.hasSuffix("/commit"))
    }

    func testUnrelatedStorage400DoesNotRetryEvenIfMessageMentionsExpiredToken() async throws {
        let body = "<Error><Code>InvalidArgument</Code><Message>ExpiredToken is not this error</Message></Error>"
        let fixture = VideoHTTPFixture([.init(200, try grant()), .init(400, body)])
        do {
            try await client(fixture).sink(for: session()).send(.init(kind: .initialization, sequence: 0, data: Data([1])))
            XCTFail("Permanent storage errors must not renew grants")
        } catch { XCTAssertEqual(error as? LiveVideoHTTPError, .rejected(statusCode: 400)) }
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testMalformedOversizedOrNonGCSErrorBodiesNeverRenewStorageGrant() async throws {
        for body in ["<Error><Code>ExpiredToken</Code>",
                     "<html><Code>ExpiredToken</Code></html>",
                     "<Error><Code>InvalidArgument</Code><Code>ExpiredToken</Code></Error>",
                     "<Error><Code><Nested>ExpiredToken</Nested></Code></Error>",
                     String(repeating: " ", count: 8_192) + expiredStorageXML,
                     "<!DOCTYPE Error [<!ENTITY code 'ExpiredToken'>]><Error><Code>&code;</Code></Error>"] {
            let fixture = VideoHTTPFixture([.init(200, try grant()), .init(400, body)])
            do {
                try await client(fixture).sink(for: session()).send(.init(kind: .initialization, sequence: 0, data: Data([1])))
                XCTFail("Only bounded, valid storage expiry errors can renew a grant")
            } catch { XCTAssertEqual(error as? LiveVideoHTTPError, .rejected(statusCode: 400)) }
            let requests = await fixture.requests
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testExpiredTokenBodyFromControl400IsNeverRetried() async throws {
        let fixture = VideoHTTPFixture([.init(400, expiredStorageXML)])
        do {
            try await client(fixture).sink(for: session()).send(.init(kind: .initialization, sequence: 0, data: Data([1])))
            XCTFail("Control denials must not be treated as expired storage grants")
        } catch { XCTAssertEqual(error as? LiveVideoHTTPError, .rejected(statusCode: 400)) }
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testRepeatedStorageExpiredToken400HasBoundedRenewalAttempts() async throws {
        var replies: [VideoHTTPFixture.Reply] = []
        for _ in 0..<3 { replies += [.init(200, try grant()), .init(400, expiredStorageXML)] }
        let fixture = VideoHTTPFixture(replies)
        do {
            try await client(fixture).sink(for: session()).send(.init(kind: .initialization, sequence: 0, data: Data([1])))
            XCTFail("A persistently expired grant must terminate bounded retries")
        } catch { XCTAssertEqual(error as? LiveVideoHTTPError, .expiredUpload) }
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 6)
    }

    func testUnsafeStorageAndForeignCommitAddressesAreRejectedBeforeSendingBytes() async throws {
        for (upload, commit) in [("file:///tmp/destination", "/api/v1/livestream/sessions/abc-123/uploads/u/commit/"),
                                 ("http://storage.example/file", "/api/v1/livestream/sessions/abc-123/uploads/u/commit/"),
                                 ("https://storage.example/file", "https://evil.example/api/v1/livestream/sessions/abc-123/uploads/u/commit/")] {
            let fixture = VideoHTTPFixture([.init(200, try grant(upload: upload, commit: commit))])
            do {
                try await client(fixture).sink(for: session()).send(.init(kind: .initialization, sequence: 0, data: Data([1])))
                XCTFail("Unsafe grant must fail")
            } catch { XCTAssertEqual(error as? LiveVideoHTTPError, .unsafeURL) }
            let requests = await fixture.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testStorageGrantCannotRequestAccountCredentials() async throws {
        let fixture = VideoHTTPFixture([.init(200, try grant(headers: ["Authorization": "Bearer secret"]))])
        do {
            try await client(fixture).sink(for: session()).send(.init(kind: .initialization, sequence: 0, data: Data([1])))
            XCTFail("Credential-bearing media grants must fail")
        } catch { XCTAssertEqual(error as? LiveVideoHTTPError, .invalidResponse) }
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testEndSessionRetriesIdempotentlyAndPreservesAuthentication() async throws {
        let fixture = VideoHTTPFixture([.init(503), .init(204)])
        try await client(fixture).sink(for: session()).finish()
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer account-secret")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-Ingest-Token"), "ingest-secret")
    }

    func testInvalidFragmentNeverRequestsAnUpload() async throws {
        let fixture = VideoHTTPFixture([])
        do {
            try await client(fixture).sink(for: session()).send(.init(kind: .media, sequence: 0, data: Data([1]), duration: .nan))
            XCTFail("Invalid duration must fail")
        } catch { XCTAssertEqual(error as? LiveVideoHTTPError, .invalidSegment) }
        let requests = await fixture.requests
        XCTAssertTrue(requests.isEmpty)
    }
}

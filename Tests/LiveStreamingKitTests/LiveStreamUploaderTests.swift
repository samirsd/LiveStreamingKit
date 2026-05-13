import XCTest
@testable import LiveStreamingKit

final class LiveStreamUploaderTests: XCTestCase {

    func testCreateSessionPostsExpectedPayload() async throws {
        let transport = MockTransport()
        let session = CreateSessionResponse(
            id: "abc",
            ingest_token: "tok",
            ingest_url: "https://example.com/api/v1/livestream/sessions/abc/segments/",
            listener_url: "https://example.com/live/abc/master.m3u8",
            master_playlist_url: "https://example.com/live/abc/master.m3u8"
        )
        await transport.queueJSON(session, statusCode: 201)

        let config = LiveStreamConfig(
            ingestBaseURL: URL(string: "https://example.com")!,
            authTokenProvider: { "auth-token" },
            multitrackRecordingID: "rec-1",
            title: "test"
        )
        let client = LiveStreamClient(config: config, transport: transport)

        let liveSession = try await client.createSession()
        XCTAssertEqual(liveSession.id, "abc")
        XCTAssertEqual(liveSession.ingestToken, "tok")

        let captured = await transport.captured
        XCTAssertEqual(captured.count, 1)
        let request = captured[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/v1/livestream/sessions/")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer auth-token")
        let body = try XCTUnwrap(request.httpBody)
        let decoded = try JSONDecoder().decode(CreateSessionRequest.self, from: body)
        XCTAssertEqual(decoded.multitrack_recording_id, "rec-1")
        XCTAssertEqual(decoded.sample_rate, 48_000)
        XCTAssertEqual(decoded.codec, "aac-lc-adts")
    }

    func testUploadSegmentSetsIngestTokenAndSegmentDuration() async throws {
        let transport = MockTransport()
        await transport.queueEmpty(statusCode: 204)
        let config = makeConfig()
        let client = LiveStreamClient(config: config, transport: transport)
        let session = makeSession()
        let segment = HLSSegment(sequence: 7, data: Data([0xFF, 0xF1]), duration: 4.0, isFinalSegment: false)

        try await client.uploadSegment(session: session, segment: segment)

        let captured = await transport.captured
        XCTAssertEqual(captured.count, 1)
        let request = captured[0]
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/v1/livestream/sessions/abc/segments/7/")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/aac")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Ingest-Token"), "tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Segment-Duration"), "4.000")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Segment-Final"))
    }

    func testUploadSegmentMarksFinal() async throws {
        let transport = MockTransport()
        await transport.queueEmpty(statusCode: 204)
        let client = LiveStreamClient(config: makeConfig(), transport: transport)
        let segment = HLSSegment(sequence: 99, data: Data([0xFF]), duration: 1.5, isFinalSegment: true)
        try await client.uploadSegment(session: makeSession(), segment: segment)
        let captured = await transport.captured
        XCTAssertEqual(captured[0].value(forHTTPHeaderField: "X-Segment-Final"), "true")
    }

    func testNotAuthenticatedWhenTokenProviderReturnsNil() async {
        let transport = MockTransport()
        let config = LiveStreamConfig(
            ingestBaseURL: URL(string: "https://example.com")!,
            authTokenProvider: { nil }
        )
        let client = LiveStreamClient(config: config, transport: transport)
        do {
            _ = try await client.createSession()
            XCTFail("expected throw")
        } catch LiveStreamError.notAuthenticated {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testUploaderRetriesOnTransientFailure() async {
        let transport = MockTransport()
        await transport.queueEmpty(statusCode: 503)
        await transport.queueEmpty(statusCode: 503)
        await transport.queueEmpty(statusCode: 204)

        let client = LiveStreamClient(config: makeConfig(), transport: transport)
        var events: [LiveStreamEvent] = []
        let collector = EventCollector()
        let uploader = LiveStreamUploader(
            client: client,
            session: makeSession(),
            maxRetries: 5,
            maxBuffered: 4,
            onEvent: { event in collector.append(event) }
        )

        await uploader.enqueue(HLSSegment(sequence: 0, data: Data([0x1]), duration: 1, isFinalSegment: false))
        await uploader.drainAndStop()
        events = await collector.snapshot()
        let retries = events.filter {
            if case .segmentRetrying = $0 { return true }; return false
        }
        let uploads = events.filter {
            if case .segmentUploaded = $0 { return true }; return false
        }
        XCTAssertGreaterThanOrEqual(retries.count, 2)
        XCTAssertEqual(uploads.count, 1)
    }

    func testUploaderDropsAfterMaxRetries() async {
        let transport = MockTransport()
        for _ in 0..<10 { await transport.queueEmpty(statusCode: 500) }

        let client = LiveStreamClient(config: makeConfig(), transport: transport)
        let collector = EventCollector()
        let uploader = LiveStreamUploader(
            client: client,
            session: makeSession(),
            maxRetries: 1,
            maxBuffered: 4,
            onEvent: { collector.append($0) }
        )
        await uploader.enqueue(HLSSegment(sequence: 42, data: Data([0x1]), duration: 1, isFinalSegment: false))
        await uploader.drainAndStop()
        let events = await collector.snapshot()
        let dropped = events.first {
            if case .segmentDropped(let seq, _) = $0, seq == 42 { return true }; return false
        }
        XCTAssertNotNil(dropped)
    }

    // MARK: - Helpers

    private func makeConfig() -> LiveStreamConfig {
        LiveStreamConfig(
            ingestBaseURL: URL(string: "https://example.com")!,
            authTokenProvider: { "auth-token" }
        )
    }

    private func makeSession() -> LiveStreamSession {
        LiveStreamSession(
            id: "abc",
            ingestToken: "tok",
            ingestURL: URL(string: "https://example.com/api/v1/livestream/sessions/abc/segments/")!,
            listenerURL: URL(string: "https://example.com/live/abc/master.m3u8")!,
            masterPlaylistURL: URL(string: "https://example.com/live/abc/master.m3u8")!
        )
    }
}

actor MockTransport: HTTPTransport {
    struct QueuedResponse {
        let statusCode: Int
        let body: Data
    }

    private(set) var captured: [URLRequest] = []
    private var responses: [QueuedResponse] = []

    func queueJSON<T: Encodable>(_ value: T, statusCode: Int) {
        let body = try? JSONEncoder().encode(value)
        responses.append(QueuedResponse(statusCode: statusCode, body: body ?? Data()))
    }

    func queueEmpty(statusCode: Int) {
        responses.append(QueuedResponse(statusCode: statusCode, body: Data()))
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured.append(request)
        guard !responses.isEmpty else {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 599,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(), response)
        }
        let queued = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: queued.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (queued.body, response)
    }
}

final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LiveStreamEvent] = []
    func append(_ event: LiveStreamEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }
    func snapshot() -> [LiveStreamEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

import XCTest
@testable import LiveStreamingKit

final class LiveStreamUploaderSemanticsTests: XCTestCase {

    func testUploadsAreSequencedInEnqueueOrder() async {
        let transport = MockTransport()
        for _ in 0..<5 { await transport.queueEmpty(statusCode: 204) }
        let client = LiveStreamClient(config: makeConfig(), transport: transport)
        let collector = EventCollector()
        let uploader = LiveStreamUploader(
            client: client,
            session: makeSession(),
            maxRetries: 0,
            maxBuffered: 16,
            onEvent: { collector.append($0) }
        )
        let sequences = [3, 1, 4, 1, 5]
        for sequence in sequences {
            await uploader.enqueue(HLSSegment(
                sequence: sequence,
                data: Data([UInt8(sequence)]),
                duration: 1,
                isFinalSegment: false
            ))
        }
        await uploader.drainAndStop()
        let uploaded = collector.snapshot().compactMap { event -> Int? in
            if case .segmentUploaded(let seq, _, _) = event { return seq }
            return nil
        }
        XCTAssertEqual(uploaded, sequences, "uploader must preserve enqueue order, even with duplicate sequence numbers")
    }

    func testBufferOverflowDropsTheOldestEnqueuedItem() async {
        // Hold upload progress so the buffer fills.
        let transport = SlowMockTransport(initialDelay: 1.5)
        for _ in 0..<10 { await transport.queueEmpty(statusCode: 204) }
        let client = LiveStreamClient(config: makeConfig(), transport: transport)
        let collector = EventCollector()
        let uploader = LiveStreamUploader(
            client: client,
            session: makeSession(),
            maxRetries: 0,
            maxBuffered: 2,
            onEvent: { collector.append($0) }
        )
        let total = 6
        for sequence in 0..<total {
            await uploader.enqueue(HLSSegment(sequence: sequence, data: Data([UInt8(sequence)]), duration: 1))
        }
        await uploader.drainAndStop()
        let drops = collector.snapshot().compactMap { event -> Int? in
            if case .segmentDropped(let seq, _) = event { return seq }
            return nil
        }
        let uploads = collector.snapshot().compactMap { event -> Int? in
            if case .segmentUploaded(let seq, _, _) = event { return seq }
            return nil
        }
        XCTAssertFalse(drops.isEmpty, "expected at least one segment to be dropped when buffer overflows")
        XCTAssertEqual(drops.count + uploads.count, total, "every enqueued segment must be either uploaded or dropped")
        // Drops are always evictions from the head, so they must be the *earliest* enqueued of the dropped set.
        let droppedAndUploaded = (drops + uploads).sorted()
        XCTAssertEqual(droppedAndUploaded, Array(0..<total), "the union of drops and uploads must equal the original sequence set")
        XCTAssertEqual(drops, drops.sorted(), "drops must be issued in increasing sequence order")
    }

    func testRetriesEmitRetryingEventsWithCorrectAttempt() async {
        let transport = MockTransport()
        await transport.queueEmpty(statusCode: 503)
        await transport.queueEmpty(statusCode: 503)
        await transport.queueEmpty(statusCode: 204)
        let client = LiveStreamClient(config: makeConfig(), transport: transport)
        let collector = EventCollector()
        let uploader = LiveStreamUploader(
            client: client,
            session: makeSession(),
            maxRetries: 5,
            maxBuffered: 4,
            onEvent: { collector.append($0) }
        )
        await uploader.enqueue(HLSSegment(sequence: 9, data: Data([0xAA]), duration: 1))
        await uploader.drainAndStop()
        let attempts = collector.snapshot().compactMap { event -> Int? in
            if case .segmentRetrying(_, let attempt) = event { return attempt }
            return nil
        }
        XCTAssertEqual(attempts, [1, 2], "expected attempts 1 and 2 before success on attempt 3")
    }

    func testDrainAndStopDoesNotAcceptFurtherEnqueues() async {
        let transport = MockTransport()
        await transport.queueEmpty(statusCode: 204)
        let client = LiveStreamClient(config: makeConfig(), transport: transport)
        let collector = EventCollector()
        let uploader = LiveStreamUploader(
            client: client,
            session: makeSession(),
            maxRetries: 0,
            maxBuffered: 4,
            onEvent: { collector.append($0) }
        )
        await uploader.drainAndStop()
        await uploader.enqueue(HLSSegment(sequence: 0, data: Data([0]), duration: 1))
        // No upload should happen
        try? await Task.sleep(nanoseconds: 200_000_000)
        let uploaded = collector.snapshot().filter {
            if case .segmentUploaded = $0 { return true }
            return false
        }
        XCTAssertTrue(uploaded.isEmpty)
    }

    func testUploaderEmitsBytesAndDurationInSegmentUploadedEvent() async {
        let transport = MockTransport()
        await transport.queueEmpty(statusCode: 204)
        let client = LiveStreamClient(config: makeConfig(), transport: transport)
        let collector = EventCollector()
        let uploader = LiveStreamUploader(
            client: client,
            session: makeSession(),
            maxRetries: 0,
            maxBuffered: 4,
            onEvent: { collector.append($0) }
        )
        let payload = Data(repeating: 0xCC, count: 1234)
        await uploader.enqueue(HLSSegment(sequence: 0, data: payload, duration: 4))
        await uploader.drainAndStop()
        let uploadEvents = collector.snapshot().compactMap { event -> (Int, Int)? in
            if case .segmentUploaded(let seq, let bytes, let ms) = event {
                return (seq, bytes)
            }
            return nil
        }
        XCTAssertEqual(uploadEvents.count, 1)
        XCTAssertEqual(uploadEvents.first?.0, 0)
        XCTAssertEqual(uploadEvents.first?.1, 1234)
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

actor SlowMockTransport: HTTPTransport {
    private let initialDelay: TimeInterval
    private var responses: [(Int, Data)] = []
    private(set) var captured: [URLRequest] = []
    private var firstCall = true

    init(initialDelay: TimeInterval) {
        self.initialDelay = initialDelay
    }

    func queueEmpty(statusCode: Int) {
        responses.append((statusCode, Data()))
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured.append(request)
        if firstCall {
            firstCall = false
            try await Task.sleep(nanoseconds: UInt64(initialDelay * 1_000_000_000))
        }
        guard !responses.isEmpty else {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 599, httpVersion: nil, headerFields: nil)!)
        }
        let (status, body) = responses.removeFirst()
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

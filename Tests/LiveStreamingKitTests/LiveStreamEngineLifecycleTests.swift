import XCTest
import AVFoundation
@testable import LiveStreamingKit

final class LiveStreamEngineLifecycleTests: XCTestCase {
    func testStopWhilePreparingEndsLateSessionWithoutPublishingLive() async throws {
        let transport = LifecycleTransport(holdFirstCreate: true)
        let events = EventCollector()
        let engine = makeEngine(transport, events: events)
        let start = Task { try await engine.start() }
        await transport.waitForFirstCreate()

        await engine.stop()
        XCTAssertEqual(engine.liveState, .stopped(reason: .requested))
        await transport.releaseFirstCreate()
        await assertCancelled(start)

        let ended = await transport.endedSessionIDs
        XCTAssertEqual(ended, ["session-1"])
        XCTAssertNil(engine.currentSession)
        XCTAssertFalse(events.snapshot().contains { if case .stateChanged(.live) = $0 { true } else { false } })
    }

    func testLateStartCannotReplaceNewBroadcast() async throws {
        let transport = LifecycleTransport(holdFirstCreate: true)
        let engine = makeEngine(transport)
        let firstStart = Task { try await engine.start() }
        await transport.waitForFirstCreate()
        await engine.stop()

        let second = try await engine.start()
        XCTAssertEqual(second.id, "session-2")
        await transport.releaseFirstCreate()
        await assertCancelled(firstStart)

        XCTAssertEqual(engine.currentSession?.id, second.id)
        guard case .live(let session, _) = engine.liveState else { return XCTFail("new session must remain live") }
        XCTAssertEqual(session.id, second.id)
        let ended = await transport.endedSessionIDs
        XCTAssertEqual(ended, ["session-1"])
        await engine.stop()
    }

    func testCancelledStartCleansUpSessionEvenWhenTransportIgnoresCancellation() async throws {
        let transport = LifecycleTransport(holdFirstCreate: true)
        let engine = makeEngine(transport)
        let start = Task { try await engine.start() }
        await transport.waitForFirstCreate()
        start.cancel()
        await transport.releaseFirstCreate()
        await assertCancelled(start)

        XCTAssertEqual(engine.liveState, .stopped(reason: .requested))
        XCTAssertNil(engine.currentSession)
        let ended = await transport.endedSessionIDs
        XCTAssertEqual(ended, ["session-1"])
    }

    func testConcurrentStopsOnlyEndSessionOnce() async throws {
        let transport = LifecycleTransport()
        let events = EventCollector()
        let engine = makeEngine(transport, events: events)
        _ = try await engine.start()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { await engine.stop() } }
        }
        let ended = await transport.endedSessionIDs
        XCTAssertEqual(ended, ["session-1"])
        XCTAssertEqual(events.snapshot().filter { $0 == .stateChanged(.stopping) }.count, 1)
        XCTAssertEqual(events.snapshot().last, .stateChanged(.stopped(reason: .requested)))
        XCTAssertNil(engine.currentSession)
    }

    func testNoIncomingAudioDegradesThenFailsAfterStartupGrace() async throws {
        let transport = LifecycleTransport()
        let events = EventCollector()
        let engine = makeEngine(transport, events: events)
        _ = try await engine.start()
        guard case .live(_, let since) = engine.liveState else { return XCTFail("expected live") }

        engine.evaluateHealth(at: since.addingTimeInterval(5))
        XCTAssertFalse(events.snapshot().contains { if case .streamHealthChanged = $0 { true } else { false } })
        engine.evaluateHealth(at: since.addingTimeInterval(15))
        engine.evaluateHealth(at: since.addingTimeInterval(31))
        XCTAssertTrue(events.snapshot().contains(.streamHealthChanged(.degraded, reason: "encode stalled 15s")))
        XCTAssertTrue(events.snapshot().contains(.streamHealthChanged(.failing, reason: "no audio encoded in 31s")))
        await engine.stop()
    }

    func testEncodedAudioWithoutSuccessfulUploadHasFiniteHealthAge() async throws {
        let transport = LifecycleTransport(rejectUploads: true)
        let events = EventCollector()
        let engine = makeEngine(transport, events: events)
        _ = try await engine.start()
        try await feedAudio(engine)
        XCTAssertTrue(events.snapshot().contains { if case .segmentEncoded = $0 { true } else { false } })

        // Previously a missing first upload became Double.greatestFiniteMagnitude
        // and Int(uploadAge) trapped on the first health evaluation.
        engine.evaluateHealth()
        XCTAssertFalse(events.snapshot().contains { if case .streamHealthChanged = $0 { true } else { false } })
        engine.evaluateHealth(at: Date().addingTimeInterval(11))
        XCTAssertTrue(events.snapshot().contains { if case .streamHealthChanged(.degraded, let reason) = $0 { reason.hasPrefix("uploads stalled") } else { false } })
        await engine.stop()
    }

    func testNewSessionResetsInterruptionAndSegmentSequence() async throws {
        let transport = LifecycleTransport()
        let engine = makeEngine(transport)
        _ = try await engine.start()
        try await feedAudio(engine)
        engine.handleAudioInterruptionBegan()
        await engine.stop()

        _ = try await engine.start()
        try await feedAudio(engine)
        await engine.stop()
        let uploads = await transport.uploadSequences
        XCTAssertEqual(uploads["session-1"]?.first, 0)
        XCTAssertEqual(uploads["session-2"]?.first, 0)
    }

    func testAudioFormatChangePreservesSegmentSequence() async throws {
        let transport = LifecycleTransport()
        let engine = makeEngine(transport)
        _ = try await engine.start()
        try await feedAudio(engine, sampleRate: 48_000)
        try await feedAudio(engine, sampleRate: 44_100)
        await engine.stop()
        let sequences = await transport.uploadSequences["session-1"] ?? []
        XCTAssertGreaterThan(sequences.count, 2)
        XCTAssertEqual(sequences, Array(0..<sequences.count))
    }

    func testEncoderFailureStopsBackendAndAllowsCleanRestart() async throws {
        let transport = LifecycleTransport()
        let failed = expectation(description: "encoder failure finished cleanup")
        let failure = LiveStreamError.encoderFailed("injected encoder failure")
        let engine = LiveStreamEngine(
            config: LiveStreamConfig(
                ingestBaseURL: URL(string: "https://example.com")!,
                authTokenProvider: { "token" }
            ),
            transport: transport
        ) { event in
            if event == .stateChanged(.failed(failure)) { failed.fulfill() }
        }
        _ = try await engine.start()
        engine.handleEncodingFailure(failure)
        await fulfillment(of: [failed], timeout: 2)

        XCTAssertEqual(engine.liveState, .failed(failure))
        XCTAssertNil(engine.currentSession)
        let ended = await transport.endedSessionIDs
        XCTAssertEqual(ended, ["session-1"])
        let restarted = try await engine.start()
        XCTAssertEqual(restarted.id, "session-2")
        await engine.stop()
    }

    func testTerminalBackendStatusStopsActiveBroadcast() async throws {
        for status in ["ended", "failed"] {
            let transport = LifecycleTransport(rejectUploads: true, terminalStatus: status)
            let stopped = expectation(description: "backend \(status) stops broadcasting")
            let engine = LiveStreamEngine(
                config: LiveStreamConfig(
                    ingestBaseURL: URL(string: "https://example.com")!,
                    authTokenProvider: { "token" },
                    segmentDuration: 0.1,
                    segmentDeliveryBudgetSeconds: 60
                ),
                transport: transport
            ) { event in
                if event == .stateChanged(.stopped(reason: .backendClosed)) { stopped.fulfill() }
            }
            _ = try await engine.start()
            await transport.waitForStatusRequest()
            try await feedAudio(engine)
            await transport.waitForUploadRequest()
            await transport.releaseTerminalStatus()
            await fulfillment(of: [stopped], timeout: 2)
            XCTAssertEqual(engine.liveState, .stopped(reason: .backendClosed))
            XCTAssertNil(engine.currentSession)
            let ended = await transport.endedSessionIDs
            XCTAssertEqual(ended, ["session-1"])
        }
    }

    private func makeEngine(_ transport: LifecycleTransport, events: EventCollector = EventCollector()) -> LiveStreamEngine {
        LiveStreamEngine(
            config: LiveStreamConfig(
                ingestBaseURL: URL(string: "https://example.com")!,
                authTokenProvider: { "token" },
                segmentDuration: 0.1,
                segmentDeliveryBudgetSeconds: 0.05
            ),
            transport: transport,
            onEvent: { events.append($0) }
        )
    }

    private func feedAudio(_ engine: LiveStreamEngine, sampleRate: Double = 48_000) async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false))
        for slice in 0..<24 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
            buffer.frameLength = 1024
            for channel in 0..<2 {
                for frame in 0..<1024 {
                    buffer.floatChannelData![channel][frame] = Float(sin(2 * .pi * 440 * Double(slice * 1024 + frame) / sampleRate)) * 0.2
                }
            }
            engine.observe(buffer: buffer, at: AVAudioFramePosition(slice * 1024))
        }
        await engine.flushProcessingQueue()
    }

    private func assertCancelled(_ task: Task<LiveStreamSession, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("start must be cancelled", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("expected cancellation, got \(error)", file: file, line: line)
        }
    }
}

private actor LifecycleTransport: HTTPTransport {
    private let holdFirstCreate: Bool
    private let rejectUploads: Bool
    private let terminalStatus: String?
    private var statusRelease: CheckedContinuation<Void, Never>?
    private var statusObserved: CheckedContinuation<Void, Never>?
    private var uploadObserved: CheckedContinuation<Void, Never>?
    private var hasAttemptedUpload = false
    private var createCount = 0
    private var createRelease: CheckedContinuation<Void, Never>?
    private var createObserved: CheckedContinuation<Void, Never>?
    private(set) var endedSessionIDs: [String] = []
    private(set) var uploadSequences: [String: [Int]] = [:]

    init(holdFirstCreate: Bool = false, rejectUploads: Bool = false, terminalStatus: String? = nil) {
        self.holdFirstCreate = holdFirstCreate
        self.rejectUploads = rejectUploads
        self.terminalStatus = terminalStatus
    }

    func waitForUploadRequest() async {
        if hasAttemptedUpload { return }
        await withCheckedContinuation { uploadObserved = $0 }
    }

    func waitForStatusRequest() async {
        if statusRelease != nil { return }
        await withCheckedContinuation { statusObserved = $0 }
    }

    func releaseTerminalStatus() {
        statusRelease?.resume()
        statusRelease = nil
    }

    func waitForFirstCreate() async {
        if createCount > 0 { return }
        await withCheckedContinuation { createObserved = $0 }
    }

    func releaseFirstCreate() {
        createRelease?.resume()
        createRelease = nil
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let components = url.pathComponents
        if request.httpMethod == "POST", components.last == "sessions" {
            createCount += 1
            let id = "session-\(createCount)"
            if createCount == 1, holdFirstCreate {
                await withCheckedContinuation { continuation in
                    createRelease = continuation
                    createObserved?.resume()
                    createObserved = nil
                }
            }
            let body = CreateSessionResponse(
                id: id, ingest_token: "ingest",
                ingest_url: "https://example.com/api/v1/livestream/sessions/\(id)/segments/",
                listener_url: "https://example.com/live/\(id)",
                master_playlist_url: "https://example.com/live/\(id)/master.m3u8"
            )
            return response(try JSONEncoder().encode(body), status: 201, url: url)
        }
        if request.httpMethod == "POST", components.last == "end" {
            // Mirror URLSession: cleanup cannot use the cancelled start task.
            try Task.checkCancellation()
            endedSessionIDs.append(components[components.count - 2])
            return response(Data(), status: 204, url: url)
        }
        if request.httpMethod == "PUT" {
            hasAttemptedUpload = true
            uploadObserved?.resume()
            uploadObserved = nil
            if rejectUploads { throw URLError(.notConnectedToInternet) }
            let id = components[components.count - 3]
            uploadSequences[id, default: []].append(Int(components.last!)!)
            return response(Data(), status: 204, url: url)
        }
        if request.httpMethod == "GET", components.last?.hasPrefix("session-") == true, let terminalStatus {
            await withCheckedContinuation { continuation in
                statusRelease = continuation
                statusObserved?.resume()
                statusObserved = nil
            }
            let data = try JSONSerialization.data(withJSONObject: ["status": terminalStatus])
            return response(data, status: 200, url: url)
        }
        return response(Data(), status: 503, url: url)
    }

    private func response(_ data: Data, status: Int, url: URL) -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

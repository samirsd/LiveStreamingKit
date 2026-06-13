import XCTest
@testable import LiveStreamingKit

/// Exercises the SocialPoller's contract: poll → diff → emit. We use a
/// `ScriptedTransport` that returns canned JSON for the status / reactions
/// endpoints, then assert that the poller emits the right `LiveStreamEvent`
/// cases in response to changing payloads.
final class LiveStreamSocialPollerTests: XCTestCase {

    func testEmitsListenerCountChangeOnce() async throws {
        let transport = ScriptedTransport()
        await transport.queueStatus(listenerCount: 3, totalListeners: 5, peakListenerCount: 4)
        await transport.queueStatus(listenerCount: 3, totalListeners: 5, peakListenerCount: 4)
        await transport.queueReactions([])
        await transport.queueReactions([])

        let collector = SocialPollerEventCollector()
        let poller = LiveStreamSocialPoller(
            client: makeClient(transport: transport),
            statusInterval: 0.05,
            reactionsInterval: 0.05,
            onEvent: { event in
                Task { await collector.append(event) }
            }
        )
        await poller.start(makeSession())
        try await wait(forSeconds: 0.4)
        await poller.stop()

        let events = await collector.snapshot()
        let listenerChanges = events.compactMap { event -> Int? in
            if case .listenerCountChanged(let n) = event { return n }
            return nil
        }
        XCTAssertEqual(listenerChanges, [3], "listener count should emit once per distinct value")
    }

    func testEmitsLifetimeAndReactionTotalsChangesOnDiff() async throws {
        let transport = ScriptedTransport()
        await transport.queueStatus(listenerCount: 1, totalListeners: 1, peakListenerCount: 1, reactionTotals: ["heart": 1])
        await transport.queueStatus(listenerCount: 1, totalListeners: 2, peakListenerCount: 2, reactionTotals: ["heart": 2])
        // Pad more identical pages so the loop can keep ticking until we
        // observe the diffs. The poller should NOT emit redundant events.
        for _ in 0..<6 {
            await transport.queueStatus(listenerCount: 1, totalListeners: 2, peakListenerCount: 2, reactionTotals: ["heart": 2])
        }
        for _ in 0..<8 { await transport.queueReactions([]) }

        let collector = SocialPollerEventCollector()
        let poller = LiveStreamSocialPoller(
            client: makeClient(transport: transport),
            statusInterval: 0.05,
            reactionsInterval: 0.05,
            onEvent: { event in
                Task { await collector.append(event) }
            }
        )
        await poller.start(makeSession())
        try await wait(forSeconds: 0.6)
        await poller.stop()

        let events = await collector.snapshot()

        let lifetimeChanges = events.compactMap { event -> (Int, Int)? in
            if case .lifetimeListenerStatsChanged(let t, let p) = event { return (t, p) }
            return nil
        }
        XCTAssertEqual(lifetimeChanges.count, 2, "lifetime should emit on each distinct (total, peak)")
        XCTAssertEqual(lifetimeChanges[0].0, 1)
        XCTAssertEqual(lifetimeChanges[1].0, 2)

        let totalsChanges = events.compactMap { event -> [String: Int]? in
            if case .reactionTotalsChanged(let t) = event { return t }
            return nil
        }
        XCTAssertEqual(totalsChanges.count, 2, "reaction totals should emit once per distinct snapshot")
        XCTAssertEqual(totalsChanges[1]["heart"], 2)
    }

    func testEmitsReactionReceivedOncePerID() async throws {
        let transport = ScriptedTransport()
        // status loop runs in parallel but doesn't matter for this test
        for _ in 0..<8 {
            await transport.queueStatus(listenerCount: 0, totalListeners: 0, peakListenerCount: 0)
        }
        await transport.queueReactions([
            ReactionDTO(id: "r1", type: "heart", ts: 1_000.0),
            ReactionDTO(id: "r2", type: "fire", ts: 1_001.0),
        ])
        // Repeat the same set — should dedupe via the seen-id set.
        await transport.queueReactions([
            ReactionDTO(id: "r1", type: "heart", ts: 1_000.0),
            ReactionDTO(id: "r2", type: "fire", ts: 1_001.0),
            ReactionDTO(id: "r3", type: "party", ts: 1_002.0),
        ])
        for _ in 0..<6 { await transport.queueReactions([]) }

        let collector = SocialPollerEventCollector()
        let poller = LiveStreamSocialPoller(
            client: makeClient(transport: transport),
            statusInterval: 0.2,  // less noise on the status side
            reactionsInterval: 0.05,
            onEvent: { event in
                Task { await collector.append(event) }
            }
        )
        await poller.start(makeSession())
        try await wait(forSeconds: 0.5)
        await poller.stop()

        let events = await collector.snapshot()
        let ids = events.compactMap { event -> String? in
            if case .reactionReceived(let r) = event { return r.id }
            return nil
        }
        XCTAssertEqual(Set(ids), ["r1", "r2", "r3"])
        XCTAssertEqual(ids.count, 3, "each reaction id should be emitted exactly once")
    }

    // MARK: - Helpers

    private func makeClient(transport: HTTPTransport) -> LiveStreamClient {
        let config = LiveStreamConfig(
            ingestBaseURL: URL(string: "https://example.test/")!,
            authTokenProvider: { "test-token" }
        )
        return LiveStreamClient(config: config, transport: transport)
    }

    private func makeSession() -> LiveStreamSession {
        LiveStreamSession(
            id: "test-session-id",
            ingestToken: "tok",
            ingestURL: URL(string: "https://example.test/i")!,
            listenerURL: URL(string: "https://example.test/live/test")!,
            masterPlaylistURL: URL(string: "https://example.test/live/test/master.m3u8")!
        )
    }

    private func wait(forSeconds seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - Helpers visible only to this test file.

private actor SocialPollerEventCollector {
    private var events: [LiveStreamEvent] = []
    func append(_ event: LiveStreamEvent) { events.append(event) }
    func snapshot() -> [LiveStreamEvent] { events }
}

/// HTTPTransport that returns scripted responses keyed by URL path suffix.
/// Queues are FIFO per endpoint kind; once exhausted, returns a 599 stub so
/// the poller keeps trying without bringing the test down.
private actor ScriptedTransport: HTTPTransport {
    private var statusResponses: [Data] = []
    private var reactionResponses: [Data] = []

    func queueStatus(
        listenerCount: Int? = nil,
        totalListeners: Int? = nil,
        peakListenerCount: Int? = nil,
        reactionTotals: [String: Int]? = nil
    ) {
        let payload = SessionStatusResponse(
            status: "live",
            listener_count: listenerCount,
            total_listeners: totalListeners,
            peak_listener_count: peakListenerCount,
            reaction_totals: reactionTotals
        )
        if let data = try? JSONEncoder().encode(payload) {
            statusResponses.append(data)
        }
    }

    func queueReactions(_ reactions: [ReactionDTO]) {
        let payload = ReactionsResponse(reactions: reactions, totals: [:])
        if let data = try? JSONEncoder().encode(payload) {
            reactionResponses.append(data)
        }
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let urlString = request.url?.absoluteString ?? ""
        let body: Data
        if urlString.contains("/reactions") {
            body = reactionResponses.isEmpty ? emptyReactions() : reactionResponses.removeFirst()
        } else {
            body = statusResponses.isEmpty ? emptyStatus() : statusResponses.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    }

    private func emptyStatus() -> Data {
        // Once queued responses are exhausted we keep returning the last
        // known shape so the loop stays inside its happy path.
        (try? JSONEncoder().encode(
            SessionStatusResponse(
                status: "live",
                listener_count: nil,
                total_listeners: nil,
                peak_listener_count: nil,
                reaction_totals: nil
            )
        )) ?? Data("{}".utf8)
    }

    private func emptyReactions() -> Data {
        (try? JSONEncoder().encode(ReactionsResponse(reactions: [], totals: [:]))) ?? Data("{}".utf8)
    }
}

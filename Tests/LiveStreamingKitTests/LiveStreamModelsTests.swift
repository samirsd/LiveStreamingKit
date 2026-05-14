import XCTest
@testable import LiveStreamingKit

final class LiveStreamModelsTests: XCTestCase {

    // MARK: - LiveStreamSession Codable

    func testLiveStreamSessionEncodesAndDecodesRoundTrip() throws {
        let original = LiveStreamSession(
            id: "abc-123",
            ingestToken: "tok",
            ingestURL: URL(string: "https://example.com/ingest")!,
            listenerURL: URL(string: "https://example.com/listen")!,
            masterPlaylistURL: URL(string: "https://example.com/master.m3u8")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LiveStreamSession.self, from: encoded)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.ingestToken, original.ingestToken)
        XCTAssertEqual(decoded.ingestURL, original.ingestURL)
        XCTAssertEqual(decoded.listenerURL, original.listenerURL)
        XCTAssertEqual(decoded.masterPlaylistURL, original.masterPlaylistURL)
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, original.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testLiveStreamSessionEquatabilityComparesAllFields() {
        let session1 = LiveStreamSession(
            id: "a", ingestToken: "t",
            ingestURL: URL(string: "https://example.com")!,
            listenerURL: URL(string: "https://example.com")!,
            masterPlaylistURL: URL(string: "https://example.com")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let session2 = LiveStreamSession(
            id: "a", ingestToken: "t",
            ingestURL: URL(string: "https://example.com")!,
            listenerURL: URL(string: "https://example.com")!,
            masterPlaylistURL: URL(string: "https://example.com")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let differentSession = LiveStreamSession(
            id: "b", ingestToken: "t",
            ingestURL: URL(string: "https://example.com")!,
            listenerURL: URL(string: "https://example.com")!,
            masterPlaylistURL: URL(string: "https://example.com")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(session1, session2)
        XCTAssertNotEqual(session1, differentSession)
    }

    // MARK: - LiveStreamConfig Equality

    func testLiveStreamConfigDefaultsAreSane() {
        let config = LiveStreamConfig(
            ingestBaseURL: URL(string: "https://example.com")!,
            authTokenProvider: { "tok" }
        )
        XCTAssertEqual(config.sampleRate, 48_000)
        XCTAssertEqual(config.stereoBitrate, 128_000)
        XCTAssertEqual(config.segmentDuration, 4.0)
        XCTAssertEqual(config.maxSegmentRetries, 3)
        XCTAssertEqual(config.maxBufferedSegments, 12)
        XCTAssertEqual(config.channelMap, .interleavedStereoMixdown)
        XCTAssertEqual(config.aiMixMode, .off)
    }

    func testLiveStreamConfigEqualityIgnoresTokenProvider() {
        let url = URL(string: "https://example.com")!
        let a = LiveStreamConfig(ingestBaseURL: url, authTokenProvider: { "a" }, title: "set")
        let b = LiveStreamConfig(ingestBaseURL: url, authTokenProvider: { "b" }, title: "set")
        XCTAssertEqual(a, b)
    }

    func testLiveStreamConfigEqualityDetectsDifferentBitrate() {
        let url = URL(string: "https://example.com")!
        let a = LiveStreamConfig(ingestBaseURL: url, authTokenProvider: { nil }, stereoBitrate: 128_000)
        let b = LiveStreamConfig(ingestBaseURL: url, authTokenProvider: { nil }, stereoBitrate: 64_000)
        XCTAssertNotEqual(a, b)
    }

    func testLiveStreamConfigEqualityDetectsDifferentAIMixMode() {
        let url = URL(string: "https://example.com")!
        let a = LiveStreamConfig(ingestBaseURL: url, authTokenProvider: { nil }, aiMixMode: .off)
        let b = LiveStreamConfig(ingestBaseURL: url, authTokenProvider: { nil }, aiMixMode: .broadcastPolish)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - ChannelMap

    func testChannelMapInterleavedStereoMixdownPresetIsConstant() {
        XCTAssertEqual(ChannelMap.interleavedStereoMixdown, ChannelMap.interleavedStereoMixdown)
    }

    func testChannelMapSummedMonoPresetIsConstant() {
        XCTAssertEqual(ChannelMap.summedMono, ChannelMap.summedMono)
    }

    func testChannelMapExplicitConvenienceBuildsExpectedWeights() {
        let map = ChannelMap.explicit(left: [0, 2], right: [1, 3])
        XCTAssertEqual(map.left.count, 2)
        XCTAssertEqual(map.right.count, 2)
        if case let .channel(index, gain) = map.left[0] {
            XCTAssertEqual(index, 0)
            XCTAssertEqual(gain, 1.0)
        } else {
            XCTFail("expected .channel(0, 1.0)")
        }
    }

    // MARK: - LiveStreamError

    func testLiveStreamErrorEqualityHandlesAssociatedValues() {
        XCTAssertEqual(LiveStreamError.notAuthenticated, .notAuthenticated)
        let url = URL(string: "https://example.com")!
        XCTAssertEqual(
            LiveStreamError.backendUnreachable(url),
            LiveStreamError.backendUnreachable(url)
        )
        XCTAssertNotEqual(
            LiveStreamError.backendRejected(statusCode: 500, body: "a"),
            LiveStreamError.backendRejected(statusCode: 500, body: "b")
        )
        XCTAssertNotEqual(
            LiveStreamError.uploadFailed(segmentSequence: 1, underlying: "boom"),
            LiveStreamError.uploadFailed(segmentSequence: 2, underlying: "boom")
        )
    }

    // MARK: - LiveStreamState

    func testLiveStreamStateIdleAndStoppedAreDistinct() {
        XCTAssertNotEqual(LiveStreamState.idle, .stopped(reason: .requested))
        XCTAssertEqual(LiveStreamState.idle, .idle)
    }

    func testLiveStreamStateLiveEqualityIgnoresDate() {
        let session = LiveStreamSession(
            id: "x", ingestToken: "t",
            ingestURL: URL(string: "https://example.com")!,
            listenerURL: URL(string: "https://example.com")!,
            masterPlaylistURL: URL(string: "https://example.com")!
        )
        let date = Date()
        let a = LiveStreamState.live(session: session, since: date)
        let b = LiveStreamState.live(session: session, since: date)
        XCTAssertEqual(a, b)
        let c = LiveStreamState.live(session: session, since: date.addingTimeInterval(1))
        XCTAssertNotEqual(a, c)
    }

    func testLiveStreamStateFailedComparesUnderlyingError() {
        let url = URL(string: "https://example.com")!
        XCTAssertEqual(
            LiveStreamState.failed(.backendUnreachable(url)),
            LiveStreamState.failed(.backendUnreachable(url))
        )
        XCTAssertNotEqual(
            LiveStreamState.failed(.backendUnreachable(url)),
            LiveStreamState.failed(.encoderUnavailable)
        )
    }

    // MARK: - LiveStreamEvent

    func testLiveStreamEventStateChangedComparesState() {
        XCTAssertEqual(LiveStreamEvent.stateChanged(.idle), .stateChanged(.idle))
        XCTAssertNotEqual(LiveStreamEvent.stateChanged(.idle), .stateChanged(.preparing))
    }

    func testLiveStreamEventListenerChangeDistinct() {
        XCTAssertEqual(LiveStreamEvent.listenerCountChanged(5), .listenerCountChanged(5))
        XCTAssertNotEqual(LiveStreamEvent.listenerCountChanged(5), .listenerCountChanged(6))
    }
}

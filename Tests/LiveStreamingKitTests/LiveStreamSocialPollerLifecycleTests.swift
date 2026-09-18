import XCTest
@testable import LiveStreamingKit

final class LiveStreamSocialPollerLifecycleTests: XCTestCase {
    func testReplacedSessionDiscardsLateStatusResponse() async {
        let transport = HeldStatusTransport()
        let live = expectation(description: "new session is live")
        let stale = expectation(description: "old session must not emit")
        stale.isInverted = true
        let client = LiveStreamClient(config: LiveStreamConfig(
            ingestBaseURL: URL(string: "https://example.test/")!, authTokenProvider: { nil }
        ), transport: transport)
        let poller = LiveStreamSocialPoller(client: client) { event in
            if case .sessionStatusChanged("live") = event { live.fulfill() }
            if case .sessionStatusChanged("ended") = event { stale.fulfill() }
            if case .listenerCountChanged(99) = event { stale.fulfill() }
        }
        await poller.start(session("old"))
        await transport.waitForOldRequest()
        await poller.start(session("new"))
        await fulfillment(of: [live], timeout: 2)
        await transport.releaseOldRequest()
        await fulfillment(of: [stale], timeout: 0.1)
        await poller.stop()
    }

    private func session(_ id: String) -> LiveStreamSession {
        let url = URL(string: "https://example.test/")!
        return LiveStreamSession(id: id, ingestToken: "", ingestURL: url,
                                 listenerURL: url, masterPlaylistURL: url)
    }
}

private actor HeldStatusTransport: HTTPTransport {
    private var response: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func waitForOldRequest() async {
        if response != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func releaseOldRequest() {
        response?.resume()
        response = nil
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        let body: String
        if path.contains("reactions") {
            body = #"{"reactions":[],"totals":{}}"#
        } else if request.url!.absoluteString.contains("/old/") {
            await withCheckedContinuation {
                response = $0
                started?.resume()
                started = nil
            }
            body = #"{"status":"ended","listener_count":99}"#
        } else {
            body = #"{"status":"live","listener_count":1}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                               httpVersion: nil, headerFields: nil)!)
    }
}

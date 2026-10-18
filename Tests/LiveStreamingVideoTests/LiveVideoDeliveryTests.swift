import Foundation
import XCTest
@testable import LiveStreamingVideo

final class LiveVideoDeliveryTests: XCTestCase, @unchecked Sendable {
    func testInitializationMustBeAcknowledgedBeforeOrderedMediaAndFinish() async {
        let gate = DeliveryTestGate()
        let started = expectation(description: "initialization started")
        let sink = DeliveryTestSink(block: .initialization, gate: gate) { segment in
            if segment.kind == .initialization { started.fulfill() }
        }
        let events = DeliveryTestEvents()
        let delivery = LiveVideoDelivery(sink: sink, maxPendingSegments: 4, onEvent: events.append)
        delivery.enqueue(initialization())
        await fulfillment(of: [started], timeout: 2)
        delivery.enqueue(media(0))
        delivery.enqueue(media(1))

        let beforeAcknowledgement = await sink.snapshot()
        XCTAssertEqual(beforeAcknowledgement.segments.map(\.kind), [.initialization])
        await gate.open()
        await delivery.finish()

        let finished = await sink.snapshot()
        XCTAssertEqual(finished.segments, [initialization(), media(0), media(1)])
        XCTAssertEqual(finished.finishCount, 1)
        XCTAssertEqual(events.snapshot(), [.segmentDelivered(sequence: 0), .segmentDelivered(sequence: 1)])
    }

    func testSlowSinkOverflowIsBoundedAndStopsInsteadOfPublishingAGap() async {
        let gate = DeliveryTestGate()
        let started = expectation(description: "initialization blocked")
        let sink = DeliveryTestSink(block: .initialization, gate: gate) { segment in
            if segment.kind == .initialization { started.fulfill() }
        }
        let events = DeliveryTestEvents()
        let delivery = LiveVideoDelivery(sink: sink, maxPendingSegments: 2, onEvent: events.append)
        delivery.enqueue(initialization())
        await fulfillment(of: [started], timeout: 2)
        for sequence in 0..<20 { delivery.enqueue(media(sequence)) }

        // finish returns even though the deliberately uncooperative sink is
        // still blocked. No overflow can create another worker or upload.
        await delivery.finish()
        let blocked = await sink.snapshot()
        XCTAssertEqual(blocked.segments, [initialization()])
        XCTAssertEqual(blocked.finishCount, 0)
        XCTAssertEqual(events.droppedSequences(), Array(0..<20))
        XCTAssertEqual(events.failureSequences().count, 1)
        await gate.open()
    }

    func testInitializationFailureDisablesQueuedAndFutureMedia() async {
        let gate = DeliveryTestGate()
        let started = expectation(description: "initialization started")
        let sink = DeliveryTestSink(block: .initialization, gate: gate, failure: .initialization) { _ in
            started.fulfill()
        }
        let events = DeliveryTestEvents()
        let delivery = LiveVideoDelivery(sink: sink, maxPendingSegments: 4, onEvent: events.append)
        delivery.enqueue(initialization())
        await fulfillment(of: [started], timeout: 2)
        delivery.enqueue(media(0))
        delivery.enqueue(media(1))
        await gate.open()
        await delivery.finish()
        delivery.enqueue(media(2))

        let finished = await sink.snapshot()
        XCTAssertEqual(finished.segments, [initialization()])
        XCTAssertEqual(finished.finishCount, 0)
        XCTAssertEqual(events.droppedSequences(), [0, 1, 2])
        XCTAssertEqual(events.failureSequences().count, 1)
        XCTAssertNil(events.failureSequences().first!)
    }

    func testMediaFailureStopsLaneWithoutSendingLaterSegments() async {
        let sink = DeliveryTestSink(failure: .media(0))
        let events = DeliveryTestEvents()
        let delivery = LiveVideoDelivery(sink: sink, maxPendingSegments: 8, onEvent: events.append)
        delivery.enqueue(initialization())
        delivery.enqueue(media(0))
        delivery.enqueue(media(1))
        delivery.enqueue(media(2))
        await delivery.finish()

        let finished = await sink.snapshot()
        XCTAssertEqual(finished.segments, [initialization(), media(0)])
        XCTAssertEqual(finished.finishCount, 0)
        XCTAssertEqual(events.failureSequences().count, 1)
        XCTAssertEqual(events.failureSequences().first!, 0)
        XCTAssertEqual(Set(events.droppedSequences()), Set([0, 1, 2]))
    }

    func testRepeatedConcurrentFinishOnlyFinishesSinkOnce() async {
        let sink = DeliveryTestSink()
        let events = DeliveryTestEvents()
        let delivery = LiveVideoDelivery(sink: sink, maxPendingSegments: 4, onEvent: events.append)
        delivery.enqueue(initialization())
        delivery.enqueue(media(0))
        async let first: Void = delivery.finish()
        async let second: Void = delivery.finish()
        _ = await (first, second)
        await delivery.finish()
        delivery.enqueue(media(1))

        let finished = await sink.snapshot()
        XCTAssertEqual(finished.segments, [initialization(), media(0)])
        XCTAssertEqual(finished.finishCount, 1)
        XCTAssertEqual(events.droppedSequences(), [1])
    }

    func testCancelReleasesFinishWaitersAndDoesNotAwaitUncooperativeSink() async {
        let gate = DeliveryTestGate()
        let started = expectation(description: "sink blocked")
        let sink = DeliveryTestSink(block: .initialization, gate: gate) { _ in started.fulfill() }
        let events = DeliveryTestEvents()
        let delivery = LiveVideoDelivery(sink: sink, maxPendingSegments: 4, onEvent: events.append)
        delivery.enqueue(initialization())
        await fulfillment(of: [started], timeout: 2)
        delivery.enqueue(media(0))
        async let finishing: Void = delivery.finish()
        await delivery.cancel()
        await finishing
        await delivery.cancel()
        await delivery.finish()
        delivery.enqueue(media(1))

        let cancelled = await sink.snapshot()
        XCTAssertEqual(cancelled.segments, [initialization()])
        XCTAssertEqual(cancelled.finishCount, 0)
        XCTAssertEqual(events.droppedSequences(), [0, 1])
        XCTAssertTrue(events.failureSequences().isEmpty)
        await gate.open()
    }

    func testMissingInitializationAndNoncontiguousMediaAreRejected() async {
        let sink = DeliveryTestSink()
        let events = DeliveryTestEvents()
        let delivery = LiveVideoDelivery(sink: sink, maxPendingSegments: 4, onEvent: events.append)
        delivery.enqueue(media(0))
        await delivery.finish()
        let rejected = await sink.snapshot()
        XCTAssertTrue(rejected.segments.isEmpty)
        XCTAssertEqual(events.failureSequences().count, 1)
        XCTAssertEqual(events.droppedSequences(), [0])

        let otherEvents = DeliveryTestEvents()
        let other = LiveVideoDelivery(sink: DeliveryTestSink(), maxPendingSegments: 4, onEvent: otherEvents.append)
        other.enqueue(initialization())
        other.enqueue(media(2))
        await other.finish()
        XCTAssertEqual(otherEvents.failureSequences().count, 1)
        XCTAssertEqual(otherEvents.droppedSequences(), [2])
    }

    func testFinishFailureIsReportedAndNotRetried() async {
        let sink = DeliveryTestSink(finishFails: true)
        let events = DeliveryTestEvents()
        let delivery = LiveVideoDelivery(sink: sink, maxPendingSegments: 4, onEvent: events.append)
        delivery.enqueue(initialization())
        delivery.enqueue(media(0))
        await delivery.finish()
        await delivery.finish()
        let finished = await sink.snapshot()
        XCTAssertEqual(finished.finishCount, 1)
        XCTAssertEqual(events.failureSequences().count, 1)
        XCTAssertNil(events.failureSequences().first!)
    }

    func testTerminalFailureIsAvailableBeforeFailureCallbackReturns() async {
        let entered = expectation(description: "failure callback suspended")
        let finished = expectation(description: "finish observes the terminal phase")
        let gate = DeliveryCallbackGate()
        defer { gate.open() }
        let delivery = LiveVideoDelivery(
            sink: DeliveryTestSink(failure: .initialization), maxPendingSegments: 4
        ) { event in
            if case .deliveryFailed = event {
                entered.fulfill()
                // Deliberately stall notification to expose the interval between
                // committing terminal state and the owner receiving its event.
                gate.block()
            }
        }
        delivery.enqueue(initialization())
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertNotNil(delivery.terminalFailure)
        let finishing = Task {
            await delivery.finish()
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertNotNil(delivery.terminalFailure)
        gate.open()
        await finishing.value
    }

    private func initialization() -> LiveVideoSegment {
        .init(kind: .initialization, sequence: 0, data: Data([0]))
    }

    private func media(_ sequence: Int) -> LiveVideoSegment {
        .init(kind: .media, sequence: sequence, data: Data([1]), duration: 1)
    }
}

private actor DeliveryTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private actor DeliveryTestSink: LiveVideoSegmentSink {
    enum Match: Equatable, Sendable {
        case initialization
        case media(Int)

        func matches(_ segment: LiveVideoSegment) -> Bool {
            switch self {
            case .initialization: return segment.kind == .initialization
            case .media(let sequence): return segment.kind == .media && segment.sequence == sequence
            }
        }
    }

    struct Snapshot: Sendable {
        let segments: [LiveVideoSegment]
        let finishCount: Int
    }

    private let block: Match?
    private let gate: DeliveryTestGate?
    private let failure: Match?
    private let finishFails: Bool
    private let onSend: @Sendable (LiveVideoSegment) -> Void
    private var segments: [LiveVideoSegment] = []
    private var finishCount = 0

    init(
        block: Match? = nil,
        gate: DeliveryTestGate? = nil,
        failure: Match? = nil,
        finishFails: Bool = false,
        onSend: @escaping @Sendable (LiveVideoSegment) -> Void = { _ in }
    ) {
        self.block = block
        self.gate = gate
        self.failure = failure
        self.finishFails = finishFails
        self.onSend = onSend
    }

    func send(_ segment: LiveVideoSegment) async throws {
        segments.append(segment)
        onSend(segment)
        if block?.matches(segment) == true { await gate?.wait() }
        if failure?.matches(segment) == true { throw TestError.expected }
    }

    func finish() async throws {
        finishCount += 1
        if finishFails { throw TestError.expected }
    }

    func snapshot() -> Snapshot { Snapshot(segments: segments, finishCount: finishCount) }
    private enum TestError: Error { case expected }
}

private final class DeliveryTestEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LiveVideoEvent] = []

    func append(_ event: LiveVideoEvent) { lock.withLock { events.append(event) } }
    func snapshot() -> [LiveVideoEvent] { lock.withLock { events } }
    func droppedSequences() -> [Int] {
        snapshot().compactMap {
            if case .deliveryDropped(let sequence) = $0 { return sequence }
            return nil
        }
    }
    func failureSequences() -> [Int?] {
        snapshot().filter {
            if case .deliveryFailed = $0 { return true }
            return false
        }.map {
            if case .deliveryFailed(let sequence, _) = $0 { return sequence }
            return nil
        }
    }
}

private final class DeliveryCallbackGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false

    func block() {
        condition.lock()
        defer { condition.unlock() }
        while !isOpen { condition.wait() }
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

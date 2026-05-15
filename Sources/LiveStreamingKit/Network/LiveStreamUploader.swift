import Foundation
import Network

/// Per-segment HLS upload pump.
///
/// Holds a FIFO of pending segments and ships them to the backend one at a
/// time. Two pieces of resilience layered on top of the simple "POST and
/// retry" baseline:
///
/// 1. **Wall-clock delivery budget.** Each segment carries an arrival
///    timestamp and the loop retries with capped exponential backoff
///    until either the segment succeeds or the budget elapses. The old
///    fixed-retry-count strategy gave up after ~4s of retries even when
///    the underlying problem was a transient outage; this version holds
///    the line for a full minute by default before dropping anything.
///
/// 2. **Reachability gating.** An `NWPathMonitor` updates `pathIsSatisfied`;
///    when it's false the upload loop sleeps in 500ms ticks instead of
///    burning retries against a dead network. Once the path recovers,
///    queued segments shoot out in order — the listener experiences a
///    short manifest gap, not a forever-broken stream.
public actor LiveStreamUploader {
    private let client: LiveStreamClient
    private let session: LiveStreamSession
    private let deliveryBudget: TimeInterval
    private let maxBackoffSeconds: TimeInterval
    private let maxBuffered: Int
    private let onEvent: @Sendable (LiveStreamEvent) -> Void

    private var inflight: Task<Void, Never>?
    private var queue: [QueuedSegment] = []
    private var droppedTotal: Int = 0
    private var stopped: Bool = false

    private let pathMonitor: NWPathMonitor
    private let pathMonitorQueue = DispatchQueue(label: "carnyx.livestream.uploader.path")
    private var pathIsSatisfied: Bool = true

    private struct QueuedSegment {
        let segment: HLSSegment
        /// Wall-clock time the segment first entered the queue. Used to
        /// enforce the delivery budget across retries — we want elapsed
        /// time *since recording*, not elapsed time spent retrying.
        let enqueuedAt: Date
    }

    public init(
        client: LiveStreamClient,
        session: LiveStreamSession,
        maxRetries: Int,
        maxBuffered: Int,
        onEvent: @escaping @Sendable (LiveStreamEvent) -> Void,
        deliveryBudgetSeconds: TimeInterval = 60,
        maxBackoffSeconds: TimeInterval = 5
    ) {
        self.client = client
        self.session = session
        // `maxRetries` is intentionally ignored — the wall-clock budget
        // makes a fixed attempt count obsolete. We keep the init parameter
        // for source compat with `LiveStreamEngine.start`.
        _ = maxRetries
        self.deliveryBudget = deliveryBudgetSeconds
        self.maxBackoffSeconds = maxBackoffSeconds
        self.maxBuffered = maxBuffered
        self.onEvent = onEvent
        self.pathMonitor = NWPathMonitor()
        Task { await self.startPathMonitor() }
    }

    public func enqueue(_ segment: HLSSegment) {
        guard !stopped else { return }
        if queue.count >= maxBuffered {
            let dropped = queue.removeFirst()
            droppedTotal += 1
            LiveStreamLog.uploader.warning(
                "queue full — dropping oldest seq=\(dropped.segment.sequence, privacy: .public) queueDepth=\(self.queue.count, privacy: .public) droppedTotal=\(self.droppedTotal, privacy: .public)"
            )
            onEvent(.segmentDropped(sequence: dropped.segment.sequence, reason: "buffer full"))
        }
        queue.append(QueuedSegment(segment: segment, enqueuedAt: Date()))
        startProcessingIfNeeded()
    }

    public func drainAndStop() async {
        stopped = true
        await inflight?.value
        pathMonitor.cancel()
    }

    private func startProcessingIfNeeded() {
        if inflight != nil { return }
        inflight = Task { [weak self] in
            await self?.processLoop()
        }
    }

    private func processLoop() async {
        while true {
            let next: QueuedSegment? = await dequeue()
            guard let queued = next else {
                inflight = nil
                return
            }
            await uploadWithRetry(queued)
        }
    }

    private func dequeue() async -> QueuedSegment? {
        if queue.isEmpty { return nil }
        return queue.removeFirst()
    }

    private func uploadWithRetry(_ queued: QueuedSegment) async {
        var attempt = 0
        let startedAt = Date()
        let deadline = queued.enqueuedAt.addingTimeInterval(deliveryBudget)
        while Date() < deadline {
            // If the device thinks there's no network at all, don't burn
            // retries — wait for the path to come back. We bound the wait
            // by the segment's deadline so a permanent-offline broadcast
            // still surfaces the drop event eventually.
            await waitForPathOrDeadline(deadline: deadline)
            if Date() >= deadline { break }

            do {
                try await client.uploadSegment(session: session, segment: queued.segment)
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                if attempt > 0 {
                    LiveStreamLog.uploader.info(
                        "uploaded after retry seq=\(queued.segment.sequence, privacy: .public) attempts=\(attempt + 1, privacy: .public) ms=\(elapsedMs, privacy: .public)"
                    )
                }
                onEvent(.segmentUploaded(
                    sequence: queued.segment.sequence,
                    bytes: queued.segment.data.count,
                    durationMs: elapsedMs
                ))
                return
            } catch {
                attempt += 1
                let backoffMillis = backoffDelay(attempt: attempt)
                let willRetry = Date().addingTimeInterval(TimeInterval(backoffMillis) / 1000) < deadline
                if !willRetry { break }
                LiveStreamLog.uploader.debug(
                    "retrying seq=\(queued.segment.sequence, privacy: .public) attempt=\(attempt, privacy: .public) backoffMs=\(backoffMillis, privacy: .public)"
                )
                onEvent(.segmentRetrying(sequence: queued.segment.sequence, attempt: attempt))
                try? await Task.sleep(nanoseconds: UInt64(backoffMillis) * 1_000_000)
            }
        }
        let totalElapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        LiveStreamLog.uploader.error(
            "delivery budget exhausted seq=\(queued.segment.sequence, privacy: .public) attempts=\(attempt, privacy: .public) elapsedMs=\(totalElapsedMs, privacy: .public)"
        )
        onEvent(.segmentDropped(
            sequence: queued.segment.sequence,
            reason: "delivery budget exhausted after \(attempt) attempt\(attempt == 1 ? "" : "s")"
        ))
    }

    /// Sleep in 500ms ticks while reachability is unsatisfied. Bounded by
    /// the segment's deadline so we always make progress (or surface a
    /// drop) within the delivery budget.
    private func waitForPathOrDeadline(deadline: Date) async {
        if pathIsSatisfied { return }
        LiveStreamLog.uploader.debug(
            "network unsatisfied — pausing uploads until path recovers (deadline=\(self.deadlineSeconds(deadline), privacy: .public)s)"
        )
        while !pathIsSatisfied && Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if pathIsSatisfied {
            LiveStreamLog.uploader.info("network path recovered — resuming uploads")
        }
    }

    private func deadlineSeconds(_ deadline: Date) -> Int {
        Int(max(0, deadline.timeIntervalSince(Date())))
    }

    /// Capped exponential backoff: 200, 500, 1.25s, 3.1s, 5, 5, 5, ...
    /// The cap matters more than the curve — without it a few retries
    /// would stretch into 30+ seconds and starve every segment behind
    /// them.
    private func backoffDelay(attempt: Int) -> Int {
        let base = 200
        let unbounded = base * Int(pow(2.5, Double(attempt - 1)))
        let cap = Int(maxBackoffSeconds * 1000)
        return min(unbounded, cap)
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { await self.updatePath(satisfied: path.status == .satisfied) }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func updatePath(satisfied: Bool) {
        guard pathIsSatisfied != satisfied else { return }
        pathIsSatisfied = satisfied
        LiveStreamLog.uploader.info(
            "reachability changed satisfied=\(satisfied, privacy: .public) queueDepth=\(self.queue.count, privacy: .public)"
        )
    }
}

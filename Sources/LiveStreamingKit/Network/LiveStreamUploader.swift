import Foundation

public actor LiveStreamUploader {
    private let client: LiveStreamClient
    private let session: LiveStreamSession
    private let maxRetries: Int
    private let maxBuffered: Int
    private let onEvent: @Sendable (LiveStreamEvent) -> Void

    private var inflight: Task<Void, Never>?
    private var queue: [HLSSegment] = []
    private var droppedTotal: Int = 0
    private var stopped: Bool = false

    public init(
        client: LiveStreamClient,
        session: LiveStreamSession,
        maxRetries: Int,
        maxBuffered: Int,
        onEvent: @escaping @Sendable (LiveStreamEvent) -> Void
    ) {
        self.client = client
        self.session = session
        self.maxRetries = maxRetries
        self.maxBuffered = maxBuffered
        self.onEvent = onEvent
    }

    public func enqueue(_ segment: HLSSegment) {
        guard !stopped else { return }
        if queue.count >= maxBuffered {
            let dropped = queue.removeFirst()
            droppedTotal += 1
            onEvent(.segmentDropped(sequence: dropped.sequence, reason: "buffer full"))
        }
        queue.append(segment)
        startProcessingIfNeeded()
    }

    public func drainAndStop() async {
        stopped = true
        await inflight?.value
    }

    private func startProcessingIfNeeded() {
        if inflight != nil { return }
        inflight = Task { [weak self] in
            await self?.processLoop()
        }
    }

    private func processLoop() async {
        while true {
            let next: HLSSegment? = await dequeue()
            guard let segment = next else {
                inflight = nil
                return
            }
            await uploadWithRetry(segment)
        }
    }

    private func dequeue() async -> HLSSegment? {
        if queue.isEmpty { return nil }
        return queue.removeFirst()
    }

    private func uploadWithRetry(_ segment: HLSSegment) async {
        var attempt = 0
        let startedAt = Date()
        while attempt <= maxRetries {
            do {
                try await client.uploadSegment(session: session, segment: segment)
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                onEvent(.segmentUploaded(
                    sequence: segment.sequence,
                    bytes: segment.data.count,
                    durationMs: elapsedMs
                ))
                return
            } catch {
                attempt += 1
                if attempt > maxRetries {
                    onEvent(.segmentDropped(
                        sequence: segment.sequence,
                        reason: "exceeded retries: \(error)"
                    ))
                    return
                }
                let backoffMillis = backoffDelay(attempt: attempt)
                onEvent(.segmentRetrying(sequence: segment.sequence, attempt: attempt))
                try? await Task.sleep(nanoseconds: UInt64(backoffMillis) * 1_000_000)
            }
        }
    }

    private func backoffDelay(attempt: Int) -> Int {
        // 200ms, 500ms, 1.2s, 2.5s, ...
        let base = 200
        return base * Int(pow(2.5, Double(attempt - 1)))
    }
}

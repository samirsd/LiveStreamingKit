import Foundation

/// A bounded, ordered network lane, independent of recording and local storage.
///
/// There is at most one suspended sink operation and `maxPendingSegments` queued
/// segments. Initialization is sent first and must succeed before any media is
/// sent. A missing segment cannot be represented by this sink contract, so an
/// overflow or sink failure permanently stops delivery rather than publishing a
/// playlist with a silent gap. The local archive is unaffected.
///
/// Sink implementations must cooperate with task cancellation. `cancel()` does
/// not wait for an uncooperative sink; it immediately rejects further work and
/// releases queued data and finish waiters.
final class LiveVideoDelivery: @unchecked Sendable {
    private enum Phase { case accepting, finishing, finished, failed, cancelled }
    private enum Work { case send(LiveVideoSegment), finish, none }

    private struct Effects {
        var events: [LiveVideoEvent] = []
        var waiters: [CheckedContinuation<Void, Never>] = []
        var cancelledTask: Task<Void, Never>?
    }

    private let sink: any LiveVideoSegmentSink
    private let maxPendingSegments: Int
    private let onEvent: @Sendable (LiveVideoEvent) -> Void
    private let lock = NSLock()
    private var phase: Phase = .accepting
    private var pending: [LiveVideoSegment] = []
    private var worker: Task<Void, Never>?
    private var workerRunning = false
    private var initializationReceived = false
    private var nextMediaSequence = 0
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var failureMessage: String?

    /// Latched with the terminal phase before events are delivered. The owner
    /// must use this snapshot for its stop result instead of relying on an event
    /// callback having run on another executor already.
    var terminalFailure: String? { lock.withLock { failureMessage } }

    init(
        sink: any LiveVideoSegmentSink,
        maxPendingSegments: Int,
        onEvent: @escaping @Sendable (LiveVideoEvent) -> Void
    ) {
        self.sink = sink
        self.maxPendingSegments = max(1, maxPendingSegments)
        self.onEvent = onEvent
    }

    /// Returns immediately without waiting for network delivery. The callback
    /// must also return quickly; callbacks execute outside the state lock.
    func enqueue(_ segment: LiveVideoSegment) {
        let effects = lock.withLock { () -> Effects in
            guard phase == .accepting else {
                return Effects(events: droppedEvents(for: [segment]))
            }

            switch segment.kind {
            case .initialization:
                guard !initializationReceived else {
                    return failLocked(segment: segment, message: "Duplicate initialization segment")
                }
            case .media:
                guard initializationReceived else {
                    return failLocked(segment: segment, message: "Media arrived before initialization")
                }
                guard segment.sequence == nextMediaSequence else {
                    return failLocked(segment: segment, message: "Media sequence must be contiguous and start at zero")
                }
            }

            guard pending.count < maxPendingSegments else {
                return failLocked(segment: segment, message: "Delivery queue full; network delivery stopped to avoid a media gap")
            }
            if segment.kind == .initialization {
                initializationReceived = true
            } else {
                nextMediaSequence += 1
            }
            pending.append(segment)
            startWorkerLocked()
            return Effects()
        }
        apply(effects)
    }

    /// Drains accepted work and finishes the healthy sink once. Concurrent and
    /// repeated calls share the same completion. A failed/cancelled lane returns
    /// without falsely completing a partial remote playlist.
    func finish() async {
        await withCheckedContinuation { continuation in
            let completedImmediately = lock.withLock { () -> Bool in
                switch phase {
                case .finished, .failed, .cancelled:
                    return true
                case .accepting, .finishing:
                    finishWaiters.append(continuation)
                    phase = .finishing
                    startWorkerLocked()
                    return false
                }
            }
            if completedImmediately { continuation.resume() }
        }
    }

    /// Cancels the single worker without awaiting an uncooperative sink.
    func cancel() async {
        let effects = lock.withLock { () -> Effects in
            guard phase == .accepting || phase == .finishing else { return Effects() }
            phase = .cancelled
            let effects = Effects(
                events: droppedEvents(for: pending),
                waiters: finishWaiters,
                cancelledTask: worker
            )
            pending.removeAll()
            finishWaiters.removeAll()
            worker = nil
            workerRunning = false
            return effects
        }
        apply(effects)
    }

    private func startWorkerLocked() {
        guard !workerRunning else { return }
        workerRunning = true
        worker = Task { [self] in await process() }
    }

    private func nextWork() -> Work {
        lock.withLock {
            guard phase == .accepting || phase == .finishing else {
                worker = nil
                workerRunning = false
                return .none
            }
            if !pending.isEmpty { return .send(pending.removeFirst()) }
            if phase == .finishing { return .finish }
            worker = nil
            workerRunning = false
            return .none
        }
    }

    private func process() async {
        while !Task.isCancelled {
            switch nextWork() {
            case .none:
                return
            case .send(let segment):
                do {
                    try await sink.send(segment)
                    let shouldReport = lock.withLock {
                        phase == .accepting || phase == .finishing
                    }
                    if shouldReport && segment.kind == .media {
                        onEvent(.segmentDelivered(sequence: segment.sequence))
                    }
                } catch {
                    reportFailure(segment: segment, message: error.localizedDescription)
                    return
                }
            case .finish:
                do {
                    try await sink.finish()
                    let effects = lock.withLock { () -> Effects in
                        guard phase == .finishing else { return Effects() }
                        phase = .finished
                        worker = nil
                        workerRunning = false
                        let effects = Effects(waiters: finishWaiters)
                        finishWaiters.removeAll()
                        return effects
                    }
                    apply(effects)
                } catch {
                    reportFailure(segment: nil, message: error.localizedDescription)
                }
                return
            }
        }
    }

    private func reportFailure(segment: LiveVideoSegment?, message: String) {
        let effects = lock.withLock { () -> Effects in
            guard phase == .accepting || phase == .finishing else { return Effects() }
            return failLocked(segment: segment, message: message)
        }
        apply(effects)
    }

    /// The lock is held. Clear the entire lane so an init/segment failure cannot
    /// be followed by seemingly continuous remote media.
    private func failLocked(segment: LiveVideoSegment?, message: String) -> Effects {
        failureMessage = message
        phase = .failed
        var discarded = pending
        if let segment { discarded.append(segment) }
        let sequence = segment?.kind == .media ? segment?.sequence : nil
        let effects = Effects(
            events: [.deliveryFailed(sequence: sequence, message: message)] + droppedEvents(for: discarded),
            waiters: finishWaiters,
            cancelledTask: worker
        )
        pending.removeAll()
        finishWaiters.removeAll()
        worker = nil
        workerRunning = false
        return effects
    }

    private func droppedEvents(for segments: [LiveVideoSegment]) -> [LiveVideoEvent] {
        segments.compactMap { segment in
            segment.kind == .media ? .deliveryDropped(sequence: segment.sequence) : nil
        }
    }

    private func apply(_ effects: Effects) {
        effects.cancelledTask?.cancel()
        for event in effects.events { onEvent(event) }
        for waiter in effects.waiters { waiter.resume() }
    }
}

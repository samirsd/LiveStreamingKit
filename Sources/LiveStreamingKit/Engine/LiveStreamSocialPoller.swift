import Foundation

/// Background poller for live-session engagement signals.
///
/// Used on both sides of the loop:
/// - **Broadcaster** — started by `LiveStreamEngine` when going live, drives
///   the listener count / reaction overlays on the control sheet.
/// - **Listener** — driven by `LiveStreamListenerViewModel` so an in-app
///   listener sees the same counts and reactions stream as the web page.
///
/// Two independent loops run while the poller is active:
///
/// - **Status loop** at ``statusInterval`` (default 5s) — fetches the session
///   summary and emits `listenerCountChanged`, `lifetimeListenerStatsChanged`,
///   and `reactionTotalsChanged` whenever any of those numbers move.
/// - **Reactions loop** at ``reactionsInterval`` (default 1s) — fetches the
///   reactions feed with a `since` cursor of the last seen ts and emits one
///   `reactionReceived` event per new row.
///
/// The poller is best-effort: transient network failures degrade silently
/// (the underlying `fetchSessionStatus` / `fetchReactions` return `nil` on
/// any error). Each loop self-terminates when ``stop()`` is called or when
/// its task is cancelled.
public actor LiveStreamSocialPoller {
    private let client: LiveStreamClient
    private let onEvent: @Sendable (LiveStreamEvent) -> Void
    private let statusInterval: TimeInterval
    private let reactionsInterval: TimeInterval

    private var session: LiveStreamSession?
    private var statusTask: Task<Void, Never>?
    private var reactionsTask: Task<Void, Never>?

    private var lastReactionTs: TimeInterval?
    private var seenReactionIDs: Set<String> = []
    private var lastListenerCount: Int = -1
    private var lastTotalListeners: Int = -1
    private var lastPeakListenerCount: Int = -1
    private var lastReactionTotalsSignature: String = ""

    public init(
        client: LiveStreamClient,
        statusInterval: TimeInterval = 5.0,
        reactionsInterval: TimeInterval = 1.0,
        onEvent: @escaping @Sendable (LiveStreamEvent) -> Void
    ) {
        self.client = client
        self.statusInterval = statusInterval
        self.reactionsInterval = reactionsInterval
        self.onEvent = onEvent
    }

    /// Begin polling for the given session. Idempotent — calling again with
    /// the same session does nothing; calling with a new session cancels the
    /// previous loops and restarts.
    public func start(_ session: LiveStreamSession) {
        if self.session?.id == session.id, statusTask != nil { return }
        cancelTasks()
        resetSeen()
        self.session = session

        statusTask = Task { [weak self] in
            guard let self else { return }
            await self.runStatusLoop()
        }
        reactionsTask = Task { [weak self] in
            guard let self else { return }
            await self.runReactionsLoop()
        }
    }

    /// Stop both loops. Safe to call multiple times.
    public func stop() {
        cancelPolling()
    }

    /// Stop both loops. Safe to call multiple times.
    public func cancelPolling() {
        cancelTasks()
        session = nil
    }

    // MARK: - Loops

    private func runStatusLoop() async {
        while !Task.isCancelled, let session = self.session {
            if let status = await client.fetchSessionStatus(session) {
                processStatus(status)
            }
            try? await Task.sleep(nanoseconds: UInt64(statusInterval * 1_000_000_000))
        }
    }

    private func runReactionsLoop() async {
        while !Task.isCancelled, let session = self.session {
            if let response = await client.fetchReactions(session, since: lastReactionTs) {
                processReactions(response.reactions)
            }
            try? await Task.sleep(nanoseconds: UInt64(reactionsInterval * 1_000_000_000))
        }
    }

    // MARK: - Processing

    private func processStatus(_ status: SessionStatusResponse) {
        if let current = status.listener_count, current != lastListenerCount {
            lastListenerCount = current
            onEvent(.listenerCountChanged(current))
        }
        let total = status.total_listeners ?? lastTotalListeners
        let peak = status.peak_listener_count ?? lastPeakListenerCount
        if total != lastTotalListeners || peak != lastPeakListenerCount {
            lastTotalListeners = total
            lastPeakListenerCount = peak
            onEvent(.lifetimeListenerStatsChanged(total: max(0, total), peak: max(0, peak)))
        }
        if let totals = status.reaction_totals {
            // String signature so we don't re-emit when nothing changed.
            let signature = totals.keys.sorted().map { "\($0)=\(totals[$0] ?? 0)" }.joined(separator: ",")
            if signature != lastReactionTotalsSignature {
                lastReactionTotalsSignature = signature
                onEvent(.reactionTotalsChanged(totals))
            }
        }
    }

    private func processReactions(_ reactions: [ReactionDTO]) {
        guard !reactions.isEmpty else { return }
        var maxTs = lastReactionTs ?? 0
        for dto in reactions {
            if seenReactionIDs.contains(dto.id) { continue }
            seenReactionIDs.insert(dto.id)
            if dto.ts > maxTs { maxTs = dto.ts }
            onEvent(.reactionReceived(LiveReactionEvent(id: dto.id, type: dto.type, ts: dto.ts)))
        }
        lastReactionTs = maxTs
        // Bound the dedupe set so a long broadcast doesn't grow unboundedly.
        if seenReactionIDs.count > 2_000 {
            seenReactionIDs.removeAll(keepingCapacity: true)
        }
    }

    private func cancelTasks() {
        statusTask?.cancel()
        statusTask = nil
        reactionsTask?.cancel()
        reactionsTask = nil
    }

    private func resetSeen() {
        lastReactionTs = nil
        seenReactionIDs.removeAll(keepingCapacity: true)
        lastListenerCount = -1
        lastTotalListeners = -1
        lastPeakListenerCount = -1
        lastReactionTotalsSignature = ""
    }
}

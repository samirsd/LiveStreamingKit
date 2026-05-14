import Foundation

public enum LiveStreamState: Sendable, Equatable {
    case idle
    case preparing
    case live(session: LiveStreamSession, since: Date)
    case stopping
    case stopped(reason: StopReason)
    case failed(LiveStreamError)

    public enum StopReason: Sendable, Equatable {
        case requested
        case recordingEnded
        case networkLost
        case backendClosed
    }
}

public enum LiveStreamEvent: Sendable, Equatable {
    case stateChanged(LiveStreamState)
    case aiMixMeasured(
        inputRMSDB: Float,
        outputPeakDB: Float,
        appliedGainDB: Float,
        limiterGainReductionDB: Float
    )
    case segmentEncoded(sequence: Int, bytes: Int, duration: TimeInterval)
    case segmentUploaded(sequence: Int, bytes: Int, durationMs: Int)
    case segmentRetrying(sequence: Int, attempt: Int)
    case segmentDropped(sequence: Int, reason: String)
    case listenerCountChanged(Int)
    case lifetimeListenerStatsChanged(total: Int, peak: Int)
    case reactionTotalsChanged([String: Int])
    case reactionReceived(LiveReactionEvent)
    case latencyMeasured(milliseconds: Int)
}

/// Single reaction record emitted by the social poller.
///
/// Surfaces in `LiveStreamControlViewModel.floatingReactions` so the
/// broadcaster sees listeners' reactions float up while live. Anonymous and
/// ephemeral on the backend — once the broadcast ends, totals persist but
/// individual ts→type rows age out per the kit's archive cap.
public struct LiveReactionEvent: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let type: String
    public let ts: TimeInterval

    public init(id: String, type: String, ts: TimeInterval) {
        self.id = id
        self.type = type
        self.ts = ts
    }
}

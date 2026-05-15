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
        /// The host app is about to terminate (force-quit or system kill);
        /// the engine attempts a best-effort flush before going down.
        case appBackgrounded
        /// An external audio interruption (call, alarm) lasted past our
        /// patience threshold and we ended the session ourselves.
        case interruptionTimedOut
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
    /// Periodic health classification while the engine is `.live`. The
    /// broadcaster UI binds to this so the user knows their stream is
    /// suffering even when they can't hear the problem from the device
    /// audio (e.g. uploads are silently failing).
    case streamHealthChanged(LiveStreamHealth, reason: String)
    /// Emitted once after `stop()` finalizes the local AAC archive. The
    /// URL is the playable AAC file (the post-AI-mix stereo mixdown that
    /// listeners actually heard). Consumers can hand this to a share
    /// sheet, import it into the library, or open it directly.
    case archiveSaved(url: URL, byteCount: Int)
}

/// Coarse health classification for an active broadcast. Drives the
/// broadcaster's "stream is degraded" chip — listeners learn the same
/// signal through the manifest-gap mechanic on the web page.
public enum LiveStreamHealth: String, Sendable, Equatable, Codable {
    /// Segments are encoding and uploading on schedule.
    case healthy
    /// Either encoding has stalled (no audio reaching the engine) or
    /// uploads are failing transiently. Audio may still be reaching some
    /// listeners; the user should check their mic + network.
    case degraded
    /// Nothing has succeeded for a long enough stretch that we expect the
    /// listener manifest to be visibly broken. The broadcaster should
    /// almost certainly stop and restart.
    case failing
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

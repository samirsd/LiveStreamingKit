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
    case segmentEncoded(sequence: Int, bytes: Int, duration: TimeInterval)
    case segmentUploaded(sequence: Int, bytes: Int, durationMs: Int)
    case segmentRetrying(sequence: Int, attempt: Int)
    case segmentDropped(sequence: Int, reason: String)
    case listenerCountChanged(Int)
    case latencyMeasured(milliseconds: Int)
}

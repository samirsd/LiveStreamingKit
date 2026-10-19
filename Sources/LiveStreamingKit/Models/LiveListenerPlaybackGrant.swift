import Foundation

/// A server-authorized, session-scoped HLS URL. Treat the URL as a credential;
/// share the human-facing listener page instead of this playback URL.
public struct LiveListenerPlaybackGrant: Equatable, Sendable {
    public let masterPlaylistURL: URL
    public let expiresAt: Date
    /// Video manifests embed short-lived private object URLs. Reauthorize before
    /// these expire, including while watching an already-ended replay.
    public let mediaURLRefreshAfterSeconds: TimeInterval?

    public init(masterPlaylistURL: URL, expiresAt: Date, mediaURLRefreshAfterSeconds: TimeInterval? = nil) {
        self.masterPlaylistURL = masterPlaylistURL
        self.expiresAt = expiresAt
        self.mediaURLRefreshAfterSeconds = mediaURLRefreshAfterSeconds
    }
}

public enum LiveListenerAccessError: Error, Equatable, Sendable {
    case authenticationRequired
    case subscriptionRequired
    case unavailable
    case invalidResponse
}

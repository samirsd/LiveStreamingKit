import Foundation

/// A server-authorized, session-scoped HLS URL. Treat the URL as a credential;
/// share the human-facing listener page instead of this playback URL.
public struct LiveListenerPlaybackGrant: Equatable, Sendable {
    public let masterPlaylistURL: URL
    public let expiresAt: Date

    public init(masterPlaylistURL: URL, expiresAt: Date) {
        self.masterPlaylistURL = masterPlaylistURL
        self.expiresAt = expiresAt
    }
}

public enum LiveListenerAccessError: Error, Equatable, Sendable {
    case authenticationRequired
    case subscriptionRequired
    case unavailable
    case invalidResponse
}

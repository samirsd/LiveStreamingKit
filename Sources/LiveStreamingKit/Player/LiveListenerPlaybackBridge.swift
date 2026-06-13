import Foundation

/// Contract the listener feature uses to drive playback without knowing
/// which player is running underneath.
///
/// `LiveStreamingKit` defines what it needs from a player; the host app
/// supplies a concrete implementation that wraps whatever playback stack
/// it already has (in Carnyx that's `AudioPlaybackManager` from
/// `PlaybackKit`). This is classic Dependency Inversion: the kit owns the
/// contract, the app owns the implementation.
///
/// The bridge is intentionally small. The listener doesn't need playlist
/// management, scrubbing, or queue manipulation — only the ability to
/// start a single HLS stream playing and stop it later. Anything richer
/// (lock-screen art, now-playing info, popup chrome) is the host app's
/// concern.
@MainActor
public protocol LiveListenerPlaybackBridge: AnyObject {
    /// Start playing a live HLS stream. The bridge owns whatever side
    /// effects this implies (audio session activation, popup-bar
    /// presentation, now-playing info). Implementations should be
    /// idempotent for the same `sessionID` — calling twice for the same
    /// session is a no-op rather than a restart.
    func playLiveStream(url: URL, title: String, sessionID: String)

    /// Stop the currently-playing live stream. No-op if a non-live track is
    /// active — the bridge must not yank an unrelated playback session.
    func stopLiveStream()

    /// True iff the host's player is currently playing this kit's live
    /// stream (not a different recording, not nothing). Used by the
    /// coordinator to dedupe re-presentations of the same session.
    var isPlayingLiveStream: Bool { get }
}

import Foundation

public enum LiveStreamError: Error, Equatable, Sendable {
    case notAuthenticated
    case backendUnreachable(URL)
    case backendRejected(statusCode: Int, body: String?)
    case encoderUnavailable
    case encoderFailed(String)
    case segmenterFailed(String)
    case uploadFailed(segmentSequence: Int, underlying: String)
    case sessionAlreadyStarted
    case sessionNotStarted
    case unsupportedAudioFormat(channelCount: Int, sampleRate: Double)
    case invalidConfiguration(String)

    /// Short, human-readable message safe to surface in UI. Plain English,
    /// lowercase per the project copy style. Designed for the broadcaster
    /// sheet's error banner — the user shouldn't see "backendRejected" or
    /// a stringified enum.
    public var userFacingDescription: String {
        switch self {
        case .notAuthenticated:
            return "not signed in — log in and try again"
        case .backendUnreachable(let url):
            return "can't reach the streaming server (\(url.host ?? url.absoluteString))"
        case .backendRejected(let statusCode, _):
            switch statusCode {
            case 400..<500:
                return "the server rejected the broadcast (code \(statusCode))"
            case 500..<600:
                return "the server is having trouble (code \(statusCode)) — try again in a moment"
            default:
                return "unexpected response from the server (code \(statusCode))"
            }
        case .encoderUnavailable:
            return "couldn't start the audio encoder on this device"
        case .encoderFailed(let detail):
            return "audio encoding failed: \(detail)"
        case .segmenterFailed(let detail):
            return "stream segmenting failed: \(detail)"
        case .uploadFailed(let seq, _):
            return "couldn't upload segment #\(seq)"
        case .sessionAlreadyStarted:
            return "a broadcast is already running"
        case .sessionNotStarted:
            return "no active broadcast"
        case .unsupportedAudioFormat(let channelCount, let sampleRate):
            return "unsupported audio format (\(channelCount)ch @ \(Int(sampleRate)) hz)"
        case .invalidConfiguration(let detail):
            return "stream configuration is invalid: \(detail)"
        }
    }

    /// One-word category for telemetry / dashboards. The user-facing string
    /// changes; this stays stable.
    public var telemetryCategory: String {
        switch self {
        case .notAuthenticated: return "auth"
        case .backendUnreachable: return "network"
        case .backendRejected(let code, _):
            return code >= 500 ? "server_error" : "server_rejected"
        case .encoderUnavailable, .encoderFailed: return "encoder"
        case .segmenterFailed: return "segmenter"
        case .uploadFailed: return "upload"
        case .sessionAlreadyStarted, .sessionNotStarted: return "state"
        case .unsupportedAudioFormat: return "format"
        case .invalidConfiguration: return "config"
        }
    }
}

/// Map an arbitrary error (typically from `URLSession` via `HTTPTransport`)
/// into a precise `LiveStreamError`. Keeps the engine's `mapStartError` and
/// future request paths in agreement on what counts as a network failure
/// vs. an auth failure vs. a server failure.
///
/// - Pre-existing `LiveStreamError` values pass through unchanged so the
///   precise case set in `LiveStreamClient.ensureSuccess` (401 → notAuthenticated,
///   etc.) isn't downgraded.
/// - `URLError` codes map to `backendUnreachable` when the box clearly can't
///   reach the server at all (DNS, offline, timeout, TLS handshake failure).
public func mapLiveStreamTransportError(_ error: Error, baseURL: URL) -> LiveStreamError {
    if let live = error as? LiveStreamError { return live }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .dnsLookupFailed,
             .cannotFindHost,
             .cannotConnectToHost,
             .timedOut,
             .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return .backendUnreachable(baseURL)
        default:
            return .backendUnreachable(baseURL)
        }
    }
    return .backendUnreachable(baseURL)
}

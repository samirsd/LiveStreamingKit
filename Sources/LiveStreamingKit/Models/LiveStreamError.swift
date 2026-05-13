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
}

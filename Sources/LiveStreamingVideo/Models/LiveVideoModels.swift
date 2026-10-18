import Foundation

/// An opt-in single-camera H.264/AAC rendition. Does not change audio-only broadcasts.
public struct LiveVideoConfiguration: Sendable, Equatable {
    public var videoWidth: Int
    public var videoHeight: Int
    public var framesPerSecond: Int
    public var videoBitrate: Int
    public var audioSampleRate: Double
    public var audioChannelCount: Int
    public var audioBitrate: Int
    public var segmentDuration: TimeInterval
    public var maxPendingSamples: Int
    public var maxPendingSegments: Int
    /// Measured audio alignment correction. Positive values delay audio.
    public var audioOffset: TimeInterval

    public init(
        videoWidth: Int = 1920, videoHeight: Int = 1080,
        framesPerSecond: Int = 30, videoBitrate: Int = 5_000_000,
        audioSampleRate: Double = 48_000, audioChannelCount: Int = 2,
        audioBitrate: Int = 128_000, segmentDuration: TimeInterval = 4,
        maxPendingSamples: Int = 12, maxPendingSegments: Int = 8,
        audioOffset: TimeInterval = 0
    ) {
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.framesPerSecond = framesPerSecond
        self.videoBitrate = videoBitrate
        self.audioSampleRate = audioSampleRate
        self.audioChannelCount = audioChannelCount
        self.audioBitrate = audioBitrate
        self.segmentDuration = segmentDuration
        self.maxPendingSamples = maxPendingSamples
        self.maxPendingSegments = maxPendingSegments
        self.audioOffset = audioOffset
    }

    public func validate() throws {
        guard (2...3840).contains(videoWidth), (2...2160).contains(videoHeight),
              videoWidth.isMultiple(of: 2), videoHeight.isMultiple(of: 2),
              (1...60).contains(framesPerSecond), (64_000...40_000_000).contains(videoBitrate),
              [44_100.0, 48_000.0].contains(audioSampleRate),
              (1...2).contains(audioChannelCount), (32_000...320_000).contains(audioBitrate),
              segmentDuration.isFinite, (1...10).contains(segmentDuration),
              segmentDuration.rounded() == segmentDuration,
              (1...120).contains(maxPendingSamples), (1...60).contains(maxPendingSegments),
              audioOffset.isFinite, (-5...5).contains(audioOffset) else {
            throw LiveVideoError.invalidConfiguration("Unsupported video/audio format, segment interval, queue bound, or alignment offset")
        }
    }
}

public enum LiveVideoMediaType: String, Sendable, Equatable {
    case audio, video
}

public struct LiveVideoSegment: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case initialization, media }
    public let kind: Kind
    /// Media sequence starts at zero; initialization has sequence zero in a separate namespace.
    public let sequence: Int
    public let data: Data
    public let duration: TimeInterval

    public init(kind: Kind, sequence: Int, data: Data, duration: TimeInterval = 0) {
        self.kind = kind
        self.sequence = sequence
        self.data = data
        self.duration = duration
    }

    public var fileName: String {
        kind == .initialization ? "init.mp4" : String(format: "segment-%06d.m4s", sequence)
    }
}

public enum LiveVideoError: Error, Sendable, Equatable, LocalizedError {
    case invalidConfiguration(String)
    case invalidSample(String)
    case encodingFailed(String)
    case invalidState(String)
    case archiveFailed(String)
    case deliveryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .invalidSample(let message),
             .encodingFailed(let message), .invalidState(let message), .archiveFailed(let message),
             .deliveryFailed(let message):
            return message
        }
    }
}

public enum LiveVideoState: Sendable, Equatable {
    case idle, recording, stopping, finished
    case failed(LiveVideoError)
}

public enum LiveVideoEvent: Sendable, Equatable {
    case stateChanged(LiveVideoState)
    case sampleDropped(LiveVideoMediaType)
    case segmentProduced(sequence: Int, bytes: Int)
    case archiveFailed(String)
    case segmentDelivered(sequence: Int)
    case deliveryFailed(sequence: Int?, message: String)
    case deliveryDropped(sequence: Int)
}

/// Implement only for an ingest service that explicitly supports H.264/AAC fMP4.
/// The existing audio-only LiveStreamClient is deliberately not an implementation.
public protocol LiveVideoSegmentSink: Sendable {
    /// Initialization must be acknowledged before any media is delivered.
    /// Calls are serialized. Throwing stops this delivery lane; the independent
    /// local archive still retains all produced media. Must honor cancellation.
    func send(_ segment: LiveVideoSegment) async throws
    /// Invoked after accepted media has drained. Must honor task cancellation.
    func finish() async throws
}

extension LiveVideoSegmentSink {
    public func finish() async throws {}
}

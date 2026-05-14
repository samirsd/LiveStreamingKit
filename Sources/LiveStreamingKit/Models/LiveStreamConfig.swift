import Foundation

public struct LiveStreamConfig: Sendable, Equatable {
    public var ingestBaseURL: URL
    public var authTokenProvider: @Sendable () async -> String?
    public var multitrackRecordingID: String?
    public var title: String?
    public var sampleRate: Double
    public var stereoBitrate: Int
    public var segmentDuration: TimeInterval
    public var channelMap: ChannelMap
    public var aiMixMode: LiveStreamAIMixMode
    public var maxSegmentRetries: Int
    public var maxBufferedSegments: Int

    public init(
        ingestBaseURL: URL,
        authTokenProvider: @escaping @Sendable () async -> String?,
        multitrackRecordingID: String? = nil,
        title: String? = nil,
        sampleRate: Double = 48_000,
        stereoBitrate: Int = 128_000,
        segmentDuration: TimeInterval = 4.0,
        channelMap: ChannelMap = .interleavedStereoMixdown,
        aiMixMode: LiveStreamAIMixMode = .off,
        maxSegmentRetries: Int = 3,
        maxBufferedSegments: Int = 12
    ) {
        self.ingestBaseURL = ingestBaseURL
        self.authTokenProvider = authTokenProvider
        self.multitrackRecordingID = multitrackRecordingID
        self.title = title
        self.sampleRate = sampleRate
        self.stereoBitrate = stereoBitrate
        self.segmentDuration = segmentDuration
        self.channelMap = channelMap
        self.aiMixMode = aiMixMode
        self.maxSegmentRetries = maxSegmentRetries
        self.maxBufferedSegments = maxBufferedSegments
    }

    public static func == (lhs: LiveStreamConfig, rhs: LiveStreamConfig) -> Bool {
        lhs.ingestBaseURL == rhs.ingestBaseURL
            && lhs.multitrackRecordingID == rhs.multitrackRecordingID
            && lhs.title == rhs.title
            && lhs.sampleRate == rhs.sampleRate
            && lhs.stereoBitrate == rhs.stereoBitrate
            && lhs.segmentDuration == rhs.segmentDuration
            && lhs.channelMap == rhs.channelMap
            && lhs.aiMixMode == rhs.aiMixMode
            && lhs.maxSegmentRetries == rhs.maxSegmentRetries
            && lhs.maxBufferedSegments == rhs.maxBufferedSegments
    }
}

public enum LiveStreamAIMixMode: String, Codable, Sendable, Equatable, CaseIterable {
    case off
    case broadcastPolish
}

public struct ChannelMap: Sendable, Equatable {
    public var left: [ChannelWeight]
    public var right: [ChannelWeight]

    public init(left: [ChannelWeight], right: [ChannelWeight]) {
        self.left = left
        self.right = right
    }

    public static let interleavedStereoMixdown = ChannelMap(
        left: [.evenChannels(gain: 1.0)],
        right: [.oddChannels(gain: 1.0)]
    )

    public static let summedMono = ChannelMap(
        left: [.allChannels(gain: 0.707)],
        right: [.allChannels(gain: 0.707)]
    )

    public static func explicit(left: [Int], right: [Int]) -> ChannelMap {
        ChannelMap(
            left: left.map { .channel($0, gain: 1.0) },
            right: right.map { .channel($0, gain: 1.0) }
        )
    }
}

public enum ChannelWeight: Sendable, Equatable {
    case channel(Int, gain: Float)
    case allChannels(gain: Float)
    case evenChannels(gain: Float)
    case oddChannels(gain: Float)
}

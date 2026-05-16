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
    /// Wall-clock budget for delivering a single segment, in seconds. The
    /// uploader will keep retrying with exponential backoff (capped) until
    /// this much time has elapsed since the segment first entered the
    /// pipeline; only then does it give up and drop. The longer this is,
    /// the more resilient the broadcast is to a transient network outage
    /// — at the cost of memory (segments queue up in the uploader's
    /// buffer) and listener-side latency (the manifest grows stale until
    /// the backlog flushes).
    public var segmentDeliveryBudgetSeconds: TimeInterval
    /// Hard ceiling on each retry's backoff. Without this, the
    /// exponential backoff would balloon past the segment-duration cadence
    /// and we'd starve subsequent segments behind a stuck retry.
    public var maxRetryBackoffSeconds: TimeInterval
    /// Where to save a local AAC copy of the broadcast. The file
    /// captures exactly what listeners heard (post-AI-mix, post-stereo-
    /// downmix), distinct from the multitrack `.wav` recording the
    /// recorder writes. Default is `.disabled` to preserve current
    /// behavior; Carnyx overrides this to `.documents`.
    public var archivePolicy: LiveStreamArchivePolicy
    /// Per-request HTTP timeout for control-plane calls (createSession,
    /// endSession, listener stats, reactions, segment uploads). Defaults to
    /// 15 s — long enough for a slow backend, short enough that a wedged
    /// network surfaces in the UI fast instead of leaving the broadcaster
    /// sheet stuck on "preparing stream" for `URLSession`'s 60 s default.
    /// Segment uploads have their own retry budget on top of this
    /// (`segmentDeliveryBudgetSeconds`).
    public var requestTimeout: TimeInterval

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
        // `maxSegmentRetries` is retained for source-compat with existing
        // callers but the uploader now ignores it in favor of the wall-
        // clock budget below. A future deprecation can drop this argument.
        maxSegmentRetries: Int = 3,
        // 60s of buffered audio at the default 4s cadence (15 segments,
        // ~1MB at 128kbps). Bumped from the previous default of 12 so the
        // queue can absorb a ~60s outage before it has to start dropping.
        maxBufferedSegments: Int = 15,
        segmentDeliveryBudgetSeconds: TimeInterval = 60,
        maxRetryBackoffSeconds: TimeInterval = 5,
        archivePolicy: LiveStreamArchivePolicy = .disabled,
        requestTimeout: TimeInterval = 15
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
        self.segmentDeliveryBudgetSeconds = segmentDeliveryBudgetSeconds
        self.maxRetryBackoffSeconds = maxRetryBackoffSeconds
        self.archivePolicy = archivePolicy
        self.requestTimeout = requestTimeout
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
            && lhs.segmentDeliveryBudgetSeconds == rhs.segmentDeliveryBudgetSeconds
            && lhs.maxRetryBackoffSeconds == rhs.maxRetryBackoffSeconds
            && lhs.archivePolicy == rhs.archivePolicy
            && lhs.requestTimeout == rhs.requestTimeout
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

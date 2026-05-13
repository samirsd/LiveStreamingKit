import Foundation

public struct PlaylistBuilder {
    public var version: Int = 6
    public var targetDuration: Int
    public var mediaSequence: Int
    public var segments: [SegmentRef]
    public var isClosed: Bool

    public struct SegmentRef: Sendable, Equatable {
        public let uri: String
        public let duration: TimeInterval
        public init(uri: String, duration: TimeInterval) {
            self.uri = uri
            self.duration = duration
        }
    }

    public init(targetDuration: Int, mediaSequence: Int, segments: [SegmentRef], isClosed: Bool) {
        self.targetDuration = targetDuration
        self.mediaSequence = mediaSequence
        self.segments = segments
        self.isClosed = isClosed
    }

    public func render() -> String {
        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:\(version)")
        lines.append("#EXT-X-TARGETDURATION:\(targetDuration)")
        lines.append("#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)")
        lines.append("#EXT-X-PLAYLIST-TYPE:EVENT")
        for segment in segments {
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append(segment.uri)
        }
        if isClosed {
            lines.append("#EXT-X-ENDLIST")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

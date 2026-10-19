import Foundation

/// A fresh session directory containing recoverable fMP4 fragments and a live
/// HLS playlist. Only writes inside its own directory. The HLS bundle preserves
/// the shared audio/video timeline; naive MP4 concatenation can lose that alignment.
final class LiveVideoArchive {
    let directoryURL: URL
    var playlistURL: URL { directoryURL.appendingPathComponent("index.m3u8") }

    private let configuration: LiveVideoConfiguration
    private let targetDuration: Int
    private var initialized = false
    private var segments: [(fileName: String, duration: TimeInterval)] = []
    private var closed = false
    private var firstTrackTimings: [LiveVideoTrackTiming] = []

    init(parentDirectory: URL, configuration: LiveVideoConfiguration) throws {
        try configuration.validate()
        guard parentDirectory.isFileURL else {
            throw LiveVideoError.archiveFailed("Recording storage must be a local directory")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LiveVideoError.archiveFailed("Recording storage is unavailable")
        }
        self.configuration = configuration
        // Fixed for the entire EVENT playlist. Leave one second for frame/AAC
        // boundary rounding; HLS does not permit changing this tag after publish.
        targetDuration = Int(configuration.segmentDuration) + 1
        directoryURL = parentDirectory.appendingPathComponent("Carnyx-LiveVideo-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        } catch {
            throw LiveVideoError.archiveFailed(error.localizedDescription)
        }
    }

    func append(_ segment: LiveVideoSegment) throws {
        guard !closed, !segment.data.isEmpty else {
            throw LiveVideoError.archiveFailed("Archive is closed or received an empty segment")
        }
        switch segment.kind {
        case .initialization:
            guard !initialized, segment.sequence == 0 else {
                throw LiveVideoError.archiveFailed("Unexpected initialization segment")
            }
        case .media:
            guard initialized, segment.sequence == segments.count,
                  segment.duration.isFinite, segment.duration > 0,
                  segment.duration.rounded() <= Double(targetDuration) else {
                throw LiveVideoError.archiveFailed("Missing initialization, media sequence, or duration")
            }
        }

        let url = directoryURL.appendingPathComponent(segment.fileName)
        try segment.data.write(to: url, options: .withoutOverwriting)
        // Ensure each fragment is durable before a playlist references it.
        let fragment = try FileHandle(forWritingTo: url)
        defer { try? fragment.close() }
        try fragment.synchronize()

        if segment.kind == .initialization {
            initialized = true
        } else {
            segments.append((segment.fileName, segment.duration))
            for timing in segment.trackTimings where !firstTrackTimings.contains(where: { $0.trackID == timing.trackID }) {
                firstTrackTimings.append(timing)
            }
        }
        if !segments.isEmpty {
            try writeTimeline(completed: false)
            try writePlaylist(isClosed: false)
        }
    }

    /// Failed captures retain an open EVENT playlist and all completed fragments.
    func finish(success: Bool) throws {
        guard !closed else { return }
        closed = true
        if !segments.isEmpty {
            try writeTimeline(completed: success)
            try writePlaylist(isClosed: success)
        }
    }

    private func writeTimeline(completed: Bool) throws {
        let timeline = LiveVideoArchiveTimeline(version: 1, completed: completed,
                                                mediaSegmentCount: segments.count, trackTimings: firstTrackTimings)
        try JSONEncoder().encode(timeline).write(to: directoryURL.appendingPathComponent("timeline.json"), options: .atomic)
    }

    private func writePlaylist(isClosed: Bool) throws {
        var lines = [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:EVENT",
            "#EXT-X-MAP:URI=\"init.mp4\""
        ]
        for segment in segments {
            lines.append(String(format: "#EXTINF:%.6f,", locale: Locale(identifier: "en_US_POSIX"), segment.duration))
            lines.append(segment.fileName)
        }
        if isClosed { lines.append("#EXT-X-ENDLIST") }
        try (lines.joined(separator: "\n") + "\n").write(to: playlistURL, atomically: true, encoding: .utf8)
    }
}

struct LiveVideoArchiveTimeline: Codable {
    let version: Int
    let completed: Bool
    let mediaSegmentCount: Int
    let trackTimings: [LiveVideoTrackTiming]
}

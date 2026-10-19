import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia

/// Converts a completed archive to a shareable H.264/AAC MP4 without re-encoding.
/// Keep the selected storage directory's access lease alive until this returns.
public enum LiveVideoArchiveExporter {
    /// Writes a fresh destination. Existing files and original fragments are never
    /// replaced. Cancellation or storage failure removes only this export's scratch
    /// files; the recoverable archive remains available for another attempt.
    public static func export(archiveDirectory: URL, to destination: URL) async throws -> URL {
        try Task.checkCancellation()
        guard archiveDirectory.isFileURL, destination.isFileURL,
              destination.pathExtension.lowercased() == "mp4" else {
            throw LiveVideoError.archiveFailed("Choose a local .mp4 destination for the video export.")
        }
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path) else {
            throw LiveVideoError.archiveFailed("A file already exists at the video export destination.")
        }
        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LiveVideoError.archiveFailed("Video export storage is unavailable.")
        }
        let scratch = parent.appendingPathComponent(".Carnyx-VideoExport-\(UUID().uuidString)", isDirectory: true)
        do {
            let timelineURL = archiveDirectory.appendingPathComponent("timeline.json")
            try requireRegularFile(timelineURL)
            let timeline = try JSONDecoder().decode(LiveVideoArchiveTimeline.self, from: Data(contentsOf: timelineURL))
            guard timeline.version == 1, timeline.completed,
                  (1...1_000_000).contains(timeline.mediaSegmentCount), timeline.trackTimings.count == 2,
                  Set(timeline.trackTimings.map(\.mediaType)) == [.audio, .video],
                  Set(timeline.trackTimings.map(\.trackID)).count == 2,
                  timeline.trackTimings.allSatisfy({ $0.presentationTimescale > 0 && $0.presentationTimeValue >= 0 }) else {
                throw LiveVideoError.archiveFailed("This archive is incomplete or has no supported audio/video timeline.")
            }
            let playlistURL = archiveDirectory.appendingPathComponent("index.m3u8")
            try requireRegularFile(playlistURL)
            guard try String(contentsOf: playlistURL, encoding: .utf8).hasSuffix("#EXT-X-ENDLIST\n") else {
                throw LiveVideoError.archiveFailed("Stop the recording successfully before exporting it.")
            }
            try files.createDirectory(at: scratch, withIntermediateDirectories: false)
            defer { try? files.removeItem(at: scratch) }
            let inputURL = scratch.appendingPathComponent("source.mp4")
            files.createFile(atPath: inputURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: inputURL)
            do {
                try copy(archiveDirectory.appendingPathComponent("init.mp4"), into: output)
                for sequence in 0..<timeline.mediaSegmentCount {
                    try copy(archiveDirectory.appendingPathComponent(String(format: "segment-%06d.m4s", sequence)), into: output)
                }
                try output.close()
            } catch {
                try? output.close()
                throw error
            }

            let asset = AVURLAsset(url: inputURL)
            let composition = AVMutableComposition()
            var tracks: [(timing: LiveVideoTrackTiming, source: AVAssetTrack, range: CMTimeRange, start: CMTime)] = []
            for timing in timeline.trackTimings {
                try Task.checkCancellation()
                let mediaType: AVMediaType = timing.mediaType == .video ? .video : .audio
                let sources = try await asset.loadTracks(withMediaType: mediaType)
                guard sources.count == 1, let source = sources.first, source.trackID == timing.trackID else {
                    throw LiveVideoError.archiveFailed("The archive's media tracks do not match its saved timeline.")
                }
                let range = try await source.load(.timeRange)
                guard range.isValid, range.start.isNumeric, range.duration.isNumeric, range.duration.seconds > 0 else {
                    throw LiveVideoError.archiveFailed("The archive contains an unreadable media track.")
                }
                let edits = try await source.load(.segments).filter { !$0.isEmpty }
                guard edits.count == 1, let edit = edits.first,
                      edit.timeMapping.source.start.isNumeric, edit.timeMapping.target.start.isNumeric else {
                    throw LiveVideoError.archiveFailed("The archive has an unsupported media edit timeline.")
                }
                // AVURLAsset independently normalizes HLS tracks to zero. Restore
                // the encoder relationship AND its AAC priming edit. The source
                // range is already trimmed by that edit; placing it at the raw AAC
                // report PTS would incorrectly advance audible audio by 2112 frames
                // on common encoders. Never hard-code that platform-specific count.
                let editOffset = CMTimeSubtract(edit.timeMapping.source.start, edit.timeMapping.target.start)
                let start = CMTimeAdd(time(timing), CMTimeAdd(editOffset, range.start))
                tracks.append((timing, source, range, start))
            }
            let origin = tracks.map(\.start).min { CMTimeCompare($0, $1) < 0 }!
            for track in tracks {
                let mediaType: AVMediaType = track.timing.mediaType == .video ? .video : .audio
                guard let target = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: track.timing.trackID) else {
                    throw LiveVideoError.archiveFailed("Unable to create an export media track.")
                }
                try target.insertTimeRange(track.range, of: track.source, at: CMTimeSubtract(track.start, origin))
                if mediaType == .video { target.preferredTransform = try await track.source.load(.preferredTransform) }
            }
            try Task.checkCancellation()
            guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                throw LiveVideoError.archiveFailed("This device cannot create a standalone video export.")
            }
            let exportedURL = scratch.appendingPathComponent("export.mp4")
            session.outputURL = exportedURL
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            let operation = ExportOperation(session)
            try await withTaskCancellationHandler {
                if #available(macOS 15.0, iOS 18.0, *) {
                    try await session.export(to: exportedURL, as: .mp4)
                } else {
                    await session.export()
                    guard session.status == .completed else {
                        throw LiveVideoError.archiveFailed(session.error?.localizedDescription ?? "The video export did not complete.")
                    }
                }
            } onCancel: {
                operation.cancel()
            }
            try Task.checkCancellation()
            let exportedFile = try FileHandle(forWritingTo: exportedURL)
            do { try exportedFile.synchronize(); try exportedFile.close() }
            catch { try? exportedFile.close(); throw error }
            try Task.checkCancellation()
            // FileManager refuses to replace a destination created during export.
            try files.moveItem(at: exportedURL, to: destination)
            return destination
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? LiveVideoError { throw error }
            throw LiveVideoError.archiveFailed("Unable to export the video: \(error.localizedDescription)")
        }
    }

    private static func time(_ timing: LiveVideoTrackTiming) -> CMTime {
        CMTime(value: timing.presentationTimeValue, timescale: timing.presentationTimescale)
    }

    private static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
            throw LiveVideoError.archiveFailed("The video archive is missing a complete media file.")
        }
    }

    private static func copy(_ source: URL, into output: FileHandle) throws {
        try Task.checkCancellation()
        try requireRegularFile(source)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
        }
    }

    private final class ExportOperation: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
        func cancel() { session.cancelExport() }
    }
}

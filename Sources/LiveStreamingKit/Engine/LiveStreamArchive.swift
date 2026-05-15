import Foundation

/// Where the broadcaster's local copy of the live stream gets written.
///
/// Each HLS segment is already a valid ADTS-AAC chunk (see `HLSSegmenter`
/// + `ADTSFraming`). Concatenating segments yields a playable `.aac` file
/// — what the listeners actually heard, post-AI-mix, post-stereo-downmix.
/// That's distinct from the multitrack `.wav` recording, which captures
/// the raw uncompressed source.
public enum LiveStreamArchivePolicy: Sendable, Equatable {
    /// Don't write a local copy. Default — preserves existing behavior.
    case disabled

    /// Write to `~/Documents/CarnyxLiveArchives/<sessionID>.aac` in the
    /// app sandbox. Survives app relaunches; visible in the Files app
    /// if the app declares `LSSupportsOpeningDocumentsInPlace` / `UIFileSharingEnabled`.
    case documents

    /// Write to NSTemporaryDirectory. Cleaned up by the OS over time —
    /// good for ephemeral "share now or lose it" UX.
    case temporary

    /// Caller-specified directory. The engine appends `<sessionID>.aac`.
    case directory(URL)
}

/// Append-only writer that streams encoded HLS segment bytes to a single
/// AAC file. Created when the engine goes live; finalized when the engine
/// stops. The actor isolation lets the engine's processing queue write
/// concurrently with the uploader without sharing a file handle across
/// threads.
public actor LiveStreamArchive {
    public let fileURL: URL
    private var handle: FileHandle?
    private var bytesWritten: Int = 0
    private var isFinalized: Bool = false

    /// Create + open the file at `fileURL`. Returns nil if the file can't
    /// be created (path is bad, no permission, parent directory missing
    /// and undoable to create).
    public init?(fileURL: URL) {
        self.fileURL = fileURL
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            // Truncate any pre-existing file at this URL so a re-used
            // sessionID doesn't accidentally append to stale data.
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            self.handle = try FileHandle(forWritingTo: fileURL)
        } catch {
            LiveStreamLog.engine.error(
                "archive failed to open path=\(fileURL.path, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Append a chunk of encoded data (typically the same `Data` we hand
    /// to the uploader). Failures are logged but not propagated — losing
    /// the archive shouldn't fail a live broadcast.
    public func append(_ data: Data) {
        guard !isFinalized, let handle else { return }
        do {
            try handle.write(contentsOf: data)
            bytesWritten += data.count
        } catch {
            LiveStreamLog.engine.error(
                "archive write failed path=\(self.fileURL.path, privacy: .public) bytes=\(data.count, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Close the file handle. Returns the final URL + byte count for
    /// telemetry. After this point, `append` becomes a no-op.
    @discardableResult
    public func finalize() -> (url: URL, bytes: Int) {
        guard !isFinalized else { return (fileURL, bytesWritten) }
        isFinalized = true
        do {
            try handle?.close()
        } catch {
            LiveStreamLog.engine.warning(
                "archive close error path=\(self.fileURL.path, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
        handle = nil
        LiveStreamLog.engine.info(
            "archive finalized path=\(self.fileURL.path, privacy: .public) bytes=\(self.bytesWritten, privacy: .public)"
        )
        return (fileURL, bytesWritten)
    }

    public var byteCount: Int { bytesWritten }
}

extension LiveStreamArchivePolicy {
    /// Resolve a destination URL for the given session id. Returns nil
    /// when archiving is disabled or the destination can't be resolved
    /// (e.g. Documents not available in a unit test sandbox).
    public func resolveURL(sessionID: String, fileManager: FileManager = .default) -> URL? {
        switch self {
        case .disabled:
            return nil
        case .documents:
            guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return nil
            }
            return docs
                .appendingPathComponent("CarnyxLiveArchives", isDirectory: true)
                .appendingPathComponent("\(sessionID).aac")
        case .temporary:
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("\(sessionID).aac")
        case .directory(let dir):
            return dir.appendingPathComponent("\(sessionID).aac")
        }
    }
}

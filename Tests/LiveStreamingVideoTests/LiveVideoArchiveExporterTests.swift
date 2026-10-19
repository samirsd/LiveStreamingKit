import XCTest
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@testable import LiveStreamingVideo

final class LiveVideoArchiveExporterTests: XCTestCase, @unchecked Sendable {
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var storedSegments: [LiveVideoSegment] = []
        private var storedErrors: [LiveVideoError] = []
        func append(_ segment: LiveVideoSegment) { lock.lock(); storedSegments.append(segment); lock.unlock() }
        func fail(_ error: LiveVideoError) { lock.lock(); storedErrors.append(error); lock.unlock() }
        var segments: [LiveVideoSegment] { lock.lock(); defer { lock.unlock() }; return storedSegments }
        var errors: [LiveVideoError] { lock.lock(); defer { lock.unlock() }; return storedErrors }
    }

    private func parent() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("video-export-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func archive(in parent: URL, audioOffset: Double = 0) async throws -> LiveVideoArchive {
        let configuration = LiveVideoConfiguration(videoWidth: 160, videoHeight: 96, framesPerSecond: 15,
            videoBitrate: 300_000, segmentDuration: 1, maxPendingSamples: 120, audioOffset: audioOffset)
        let archive = try LiveVideoArchive(parentDirectory: parent, configuration: configuration)
        let output = Output()
        let writer = try FragmentedMP4Writer(configuration: configuration,
            epoch: CMTime(seconds: 100, preferredTimescale: 48_000),
            onSegment: { output.append($0) }, onFailure: { output.fail($0) }, onDrop: { _ in })
        var videoFrame = 0
        var audioFrame = 0
        while Double(videoFrame) / 15 < 3 || Double(audioFrame) / 48_000 < 3 {
            let videoTime = Double(videoFrame) / 15
            let audioTime = Double(audioFrame) / 48_000
            if videoTime <= audioTime, videoTime < 3 {
                XCTAssertTrue(writer.appendVideo(try FragmentedMP4Fixtures.video(frame: videoFrame),
                    at: CMTime(seconds: 100 + videoTime, preferredTimescale: 48_000)))
                videoFrame += 1
            } else if audioTime < 3 {
                XCTAssertTrue(writer.appendAudio(try FragmentedMP4Fixtures.audio(firstFrame: audioFrame),
                    at: CMTime(seconds: 100 + audioTime, preferredTimescale: 48_000)))
                audioFrame += 1024
            } else { break }
            try await Task.sleep(for: .milliseconds(3))
        }
        try await writer.finish()
        XCTAssertTrue(output.errors.isEmpty, "\(output.errors)")
        for segment in output.segments { try archive.append(segment) }
        try archive.finish(success: true)
        return archive
    }

    func testPassthroughMP4DecodesAndPreservesBothOffsetSignsWithoutTenSecondLeadIn() async throws {
        let parent = try parent()
        var differences: [Double] = []
        for offset in [-0.25, 0, 0.25] {
            let archive = try await archive(in: parent, audioOffset: offset)
            let originalFiles = try FileManager.default.contentsOfDirectory(at: archive.directoryURL, includingPropertiesForKeys: nil)
            let originals = try Dictionary(uniqueKeysWithValues: originalFiles.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
            let destination = parent.appendingPathComponent("offset-\(offset).mp4")
            let result = try await LiveVideoArchiveExporter.export(archiveDirectory: archive.directoryURL, to: destination)
            XCTAssertEqual(result, destination)
            for file in originalFiles { XCTAssertEqual(try Data(contentsOf: file), originals[file.lastPathComponent]) }

            let asset = AVURLAsset(url: destination)
            let duration = try await asset.load(.duration).seconds
            XCTAssertGreaterThan(duration, 2.9)
            XCTAssertLessThan(duration, 3.5, "The HLS AAC safety origin must not become ten seconds of blank video")
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let video = try XCTUnwrap(videoTracks.first)
            let audio = try XCTUnwrap(audioTracks.first)
            let videoEdits = try await video.load(.segments).filter { !$0.isEmpty }
            let audioEdits = try await audio.load(.segments).filter { !$0.isEmpty }
            let videoPTS = try XCTUnwrap(videoEdits.first).timeMapping.target.start.seconds
            let audioPTS = try XCTUnwrap(audioEdits.first).timeMapping.target.start.seconds
            differences.append(audioPTS - videoPTS)
            XCTAssertEqual(min(videoPTS, audioPTS), 0, accuracy: 1.0 / 48_000)
            XCTAssertEqual(audioPTS - videoPTS, offset, accuracy: 1.0 / 48_000)
            let decoded = try decode(asset: asset, video: video, audio: audio,
                videoRange: try XCTUnwrap(videoEdits.first).timeMapping.target,
                audioRange: try XCTUnwrap(audioEdits.first).timeMapping.target)
            XCTAssertEqual(decoded.frames, 45)
            XCTAssertGreaterThan(decoded.audioFrames, 140_000)
            XCTAssertLessThan(decoded.audioFrames, 150_000)
            XCTAssertEqual(decoded.firstVideoPTS, videoPTS, accuracy: 1.0 / 48_000)
            XCTAssertEqual(decoded.firstAudioPTS, audioPTS, accuracy: 1.0 / 48_000)
            #if os(macOS)
            try verifyWithFFprobeIfAvailable(destination, expectedOffset: offset)
            #endif
            // Optional artifacts for an independent ffprobe/ffmpeg inspection.
            if let artifactPath = ProcessInfo.processInfo.environment["LIVE_VIDEO_EXPORT_FIXTURE_DIRECTORY"] {
                let folder = URL(fileURLWithPath: artifactPath, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: destination, to: folder.appendingPathComponent(destination.lastPathComponent))
            }
        }
        XCTAssertEqual(differences[0] - differences[1], -0.25, accuracy: 1.0 / 48_000)
        XCTAssertEqual(differences[2] - differences[1], 0.25, accuracy: 1.0 / 48_000)
    }

    func testExistingDestinationAndMissingStorageNeverReplaceUserData() async throws {
        let parent = try parent()
        let archive = try await archive(in: parent)
        let destination = parent.appendingPathComponent("existing.mp4")
        let sentinel = Data("keep this recording".utf8)
        try sentinel.write(to: destination)
        do { _ = try await LiveVideoArchiveExporter.export(archiveDirectory: archive.directoryURL, to: destination); XCTFail() } catch {}
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        do { _ = try await LiveVideoArchiveExporter.export(archiveDirectory: archive.directoryURL,
            to: parent.appendingPathComponent("missing/output.mp4")); XCTFail() } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.playlistURL.path))
    }

    func testMissingFragmentAndIncompleteArchiveFailWithoutPartialMP4() async throws {
        let parent = try parent()
        let archive = try await archive(in: parent)
        let destination = parent.appendingPathComponent("missing-fragment.mp4")
        try FileManager.default.removeItem(at: archive.directoryURL.appendingPathComponent("segment-000000.m4s"))
        do { _ = try await LiveVideoArchiveExporter.export(archiveDirectory: archive.directoryURL, to: destination); XCTFail() } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: parent.path).contains { $0.hasPrefix(".Carnyx-VideoExport-") })
        let incomplete = try LiveVideoArchive(parentDirectory: parent, configuration: .init())
        do { _ = try await LiveVideoArchiveExporter.export(archiveDirectory: incomplete.directoryURL, to: destination); XCTFail() } catch {}
    }

    func testCancellationPreservesArchiveAndCreatesNoOutput() async throws {
        let parent = try parent()
        let archive = try await archive(in: parent)
        let destination = parent.appendingPathComponent("cancelled.mp4")
        let archiveDirectory = archive.directoryURL
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LiveVideoArchiveExporter.export(archiveDirectory: archiveDirectory, to: destination)
        }
        do { _ = try await task.value; XCTFail() } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.playlistURL.path))
    }

    func testCancellationDuringCopyCleansOnlyOwnedScratchFiles() async throws {
        let parent = try parent()
        let archive = try await archive(in: parent)
        let initialization = archive.directoryURL.appendingPathComponent("init.mp4")
        let handle = try FileHandle(forWritingTo: initialization)
        let start = try handle.seekToEnd()
        // A valid, sparse ISO-BMFF free box makes copying long enough to cancel
        // after export has actually started, without a huge in-memory fixture.
        let paddingSize: UInt32 = 128 * 1024 * 1024
        var bigEndianSize = paddingSize.bigEndian
        try withUnsafeBytes(of: &bigEndianSize) { try handle.write(contentsOf: $0) }
        try handle.write(contentsOf: Data("free".utf8))
        try handle.truncate(atOffset: start + UInt64(paddingSize))
        try handle.close()
        let directory = archive.directoryURL
        let destination = parent.appendingPathComponent("cancel-copy.mp4")
        let task = Task.detached { try await LiveVideoArchiveExporter.export(archiveDirectory: directory, to: destination) }
        var sawScratch = false
        for _ in 0..<1_000 {
            if try FileManager.default.contentsOfDirectory(atPath: parent.path).contains(where: { $0.hasPrefix(".Carnyx-VideoExport-") }) {
                sawScratch = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation during copying must not publish a finished MP4") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertTrue(sawScratch, "The cancellation test must reach a running export")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try initialization.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int(start + UInt64(paddingSize)))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: parent.path).contains { $0.hasPrefix(".Carnyx-VideoExport-") })
    }

    func testStorageWriteDenialPreservesSourceAndReportsArchiveFailure() async throws {
        #if canImport(Darwin)
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions") }
        #endif
        let parent = try parent()
        let archive = try await archive(in: parent)
        let denied = parent.appendingPathComponent("unwritable", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path) }
        let destination = denied.appendingPathComponent("recording.mp4")
        do {
            _ = try await LiveVideoArchiveExporter.export(archiveDirectory: archive.directoryURL, to: destination)
            XCTFail("Storage failures must not be reported as a saved video")
        } catch let error as LiveVideoError {
            guard case .archiveFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.playlistURL.path))
    }

    private func decode(asset: AVAsset, video: AVAssetTrack, audio: AVAssetTrack,
                        videoRange: CMTimeRange, audioRange: CMTimeRange) throws -> (frames: Int, audioFrames: Int, firstVideoPTS: Double, firstAudioPTS: Double) {
        // Restrict each decoder to its real media edit. Otherwise AVAssetReader
        // creates a black/silent sample covering a leading empty edit; that filler
        // is not an encoded frame and does not identify the first captured sample.
        let videoReader = try AVAssetReader(asset: asset)
        videoReader.timeRange = videoRange
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoReader.add(videoOutput)
        XCTAssertTrue(videoReader.startReading())
        let audioReader = try AVAssetReader(asset: asset)
        audioReader.timeRange = audioRange
        let audioOutput = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        audioReader.add(audioOutput)
        XCTAssertTrue(audioReader.startReading())
        var frames = 0
        var firstVideoPTS: Double?
        while let sample = videoOutput.copyNextSampleBuffer() {
            XCTAssertNotNil(CMSampleBufferGetImageBuffer(sample))
            if firstVideoPTS == nil { firstVideoPTS = CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds }
            frames += 1
        }
        var audioFrames = 0
        var firstAudioPTS: Double?
        while let sample = audioOutput.copyNextSampleBuffer() {
            if firstAudioPTS == nil { firstAudioPTS = CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds }
            audioFrames += CMSampleBufferGetNumSamples(sample)
        }
        XCTAssertEqual(videoReader.status, .completed, "\(String(describing: videoReader.error))")
        XCTAssertEqual(audioReader.status, .completed, "\(String(describing: audioReader.error))")
        return (frames, audioFrames, try XCTUnwrap(firstVideoPTS), try XCTUnwrap(firstAudioPTS))
    }

    #if os(macOS)
    /// Independent ISO-BMFF interpretation; never installs a tool on a test host.
    private func verifyWithFFprobeIfAvailable(_ url: URL, expectedOffset: Double) throws {
        guard let executable = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-v", "error", "-show_entries", "stream=codec_name,start_time:format=duration", "-of", "json", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let streams = try XCTUnwrap(json["streams"] as? [[String: Any]])
        let video = try XCTUnwrap(streams.first { $0["codec_name"] as? String == "h264" })
        let audio = try XCTUnwrap(streams.first { $0["codec_name"] as? String == "aac" })
        let videoStart = try XCTUnwrap(Double(try XCTUnwrap(video["start_time"] as? String)))
        let audioStart = try XCTUnwrap(Double(try XCTUnwrap(audio["start_time"] as? String)))
        XCTAssertEqual(audioStart - videoStart, expectedOffset, accuracy: 1.0 / 48_000)
        XCTAssertEqual(min(videoStart, audioStart), 0, accuracy: 1.0 / 48_000)
    }
    #endif
}

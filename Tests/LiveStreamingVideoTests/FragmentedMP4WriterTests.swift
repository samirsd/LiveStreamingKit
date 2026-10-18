import XCTest
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@testable import LiveStreamingVideo

final class FragmentedMP4WriterTests: XCTestCase, @unchecked Sendable {
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var storedSegments: [LiveVideoSegment] = []
        private var storedErrors: [LiveVideoError] = []
        private var storedDrops: [LiveVideoMediaType] = []
        func segment(_ value: LiveVideoSegment) { lock.lock(); storedSegments.append(value); lock.unlock() }
        func failure(_ value: LiveVideoError) { lock.lock(); storedErrors.append(value); lock.unlock() }
        func drop(_ value: LiveVideoMediaType) { lock.lock(); storedDrops.append(value); lock.unlock() }
        var segments: [LiveVideoSegment] { lock.lock(); defer { lock.unlock() }; return storedSegments }
        var errors: [LiveVideoError] { lock.lock(); defer { lock.unlock() }; return storedErrors }
        var drops: [LiveVideoMediaType] { lock.lock(); defer { lock.unlock() }; return storedDrops }
    }

    private func configuration(maxPendingSamples: Int = 120, audioOffset: TimeInterval = 0) -> LiveVideoConfiguration {
        LiveVideoConfiguration(videoWidth: 160, videoHeight: 96, framesPerSecond: 15,
                               videoBitrate: 300_000, audioSampleRate: 48_000,
                               audioChannelCount: 2, audioBitrate: 128_000,
                               segmentDuration: 1, maxPendingSamples: maxPendingSamples,
                               audioOffset: audioOffset)
    }

    private func makeWriter(_ output: Output, config: LiveVideoConfiguration? = nil) throws -> FragmentedMP4Writer {
        try FragmentedMP4Writer(configuration: config ?? configuration(),
                                epoch: CMTime(seconds: 100, preferredTimescale: 48_000),
                                onSegment: { output.segment($0) },
                                onFailure: { output.failure($0) }, onDrop: { output.drop($0) })
    }

    func testRealH264AACFragmentsDecodeAndRetainSharedClockAlignment() async throws {
        let output = Output()
        let writer = try makeWriter(output)
        try await feed(writer, seconds: 3)
        try await writer.finish()
        // Finish is idempotent, and subsequent admissions are rejected.
        try await writer.finish()
        XCTAssertFalse(writer.appendVideo(try videoSample(frame: 100), at: CMTime(seconds: 104, preferredTimescale: 48_000)))
        XCTAssertTrue(output.errors.isEmpty, "\(output.errors)")
        XCTAssertEqual(output.segments.first?.kind, .initialization)
        let media = output.segments.filter { $0.kind == .media }
        XCTAssertGreaterThanOrEqual(media.count, 3)
        XCTAssertEqual(media.map(\.sequence), Array(0..<media.count))
        XCTAssertTrue(media.allSatisfy { $0.duration > 0 && $0.duration < 1.2 })
        XCTAssertTrue(output.segments[0].data.range(of: Data("moov".utf8)) != nil)
        XCTAssertTrue(output.segments[0].data.range(of: Data("mvex".utf8)) != nil)
        XCTAssertTrue(media.allSatisfy { $0.data.range(of: Data("moof".utf8)) != nil && $0.data.range(of: Data("mdat".utf8)) != nil })

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-video-writer-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try output.segments.reduce(into: Data()) { $0.append($1.data) }.write(to: url)
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let videoFormats = try await videoTrack.load(.formatDescriptions)
        let videoFormat = try XCTUnwrap(videoFormats.first)
        let audioFormats = try await audioTrack.load(.formatDescriptions)
        let audioFormat = try XCTUnwrap(audioFormats.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(videoFormat), kCMVideoCodecType_H264)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(audioFormat), kAudioFormatMPEG4AAC)
        let videoRange = try await videoTrack.load(.timeRange)
        let audioRange = try await audioTrack.load(.timeRange)
        let duration = try await asset.load(.duration)
        XCTAssertLessThan(duration.seconds, 3.2, "AVFoundation must not expose the ten-second AAC safety origin as recording time")
        XCTAssertLessThan(abs(videoRange.start.seconds - audioRange.start.seconds), 0.1)
        XCTAssertGreaterThan(videoRange.duration.seconds, 2.5)
        XCTAssertGreaterThan(audioRange.duration.seconds, 2.5)

        // Decode actual compressed output, rather than just inspecting a manifest or header.
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        reader.add(videoOutput)
        reader.add(audioOutput)
        XCTAssertTrue(reader.startReading(), "\(String(describing: reader.error))")
        var decodedFrames = 0
        while let sample = videoOutput.copyNextSampleBuffer() {
            XCTAssertNotNil(CMSampleBufferGetImageBuffer(sample))
            decodedFrames += 1
        }
        var decodedAudioFrames = 0
        while let sample = audioOutput.copyNextSampleBuffer() { decodedAudioFrames += CMSampleBufferGetNumSamples(sample) }
        XCTAssertEqual(reader.status, .completed, "\(String(describing: reader.error))")
        XCTAssertGreaterThan(decodedFrames, 35)
        XCTAssertGreaterThan(decodedAudioFrames, 120_000)
    }

    func testBothAudioOffsetSignsArePreservedInActualFragmentClock() async throws {
        var differences: [Double] = []
        for offset in [-0.25, 0, 0.25] {
            let output = Output()
            let writer = try makeWriter(output, config: configuration(audioOffset: offset))
            try await feed(writer, seconds: 1.5)
            try await writer.finish()
            let media = try XCTUnwrap(output.segments.first { $0.kind == .media })
            let times = try FragmentedMP4Fixtures.decodeTimes(in: media.data)
            // AVAssetWriter assigns track IDs in add-input order: video then audio.
            let videoTicks = try XCTUnwrap(times[1])
            let audioTicks = try XCTUnwrap(times[2])
            let videoTime = Double(videoTicks) / 60_000
            let audioTime = Double(audioTicks) / 48_000
            XCTAssertEqual(videoTime, 10, accuracy: 0.001)
            XCTAssertGreaterThan(audioTime, 9, "AAC priming must not underflow an unsigned fragment timestamp")
            differences.append(audioTime - videoTime)
        }
        // AAC priming is an encoder property; compare relative corrections to avoid
        // hard-coding a platform-specific priming-frame count.
        XCTAssertEqual(differences[0] - differences[1], -0.25, accuracy: 1.0 / 48_000)
        XCTAssertEqual(differences[2] - differences[1], 0.25, accuracy: 1.0 / 48_000)
    }

    func testConcurrentFinishWaitersSeeAllCallbacksBeforeReturning() async throws {
        let output = Output()
        let writer = try makeWriter(output)
        try await feed(writer, seconds: 1.5)
        async let first: Void = writer.finish()
        async let second: Void = writer.finish()
        try await first
        try await second
        let count = output.segments.count
        XCTAssertGreaterThan(count, 1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(output.segments.count, count)
        XCTAssertTrue(output.errors.isEmpty)
    }

    func testCancelAfterRealSegmentDoesNotDeadlockOrDeliverLaterSegments() async throws {
        let output = Output()
        let writer = try makeWriter(output)
        try await feed(writer, seconds: 1.5)
        XCTAssertFalse(output.segments.isEmpty)
        writer.cancel()
        do { try await writer.finish(); XCTFail("Cancellation must terminate outstanding finish work") } catch {}
        let count = output.segments.count
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(output.segments.count, count)
        XCTAssertTrue(output.errors.isEmpty)
    }

    func testRejectsNonMonotonicHostClockAndFinishesWithSameError() async throws {
        let output = Output()
        let writer = try makeWriter(output)
        let time = CMTime(seconds: 100, preferredTimescale: 48_000)
        XCTAssertTrue(writer.appendVideo(try videoSample(frame: 0), at: time))
        XCTAssertTrue(writer.appendVideo(try videoSample(frame: 1), at: time))
        do {
            try await writer.finish()
            XCTFail("An out-of-order frame must fail the writer")
        } catch let error as LiveVideoError {
            guard case .invalidSample = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(output.errors, [error])
        }
        XCTAssertFalse(writer.appendAudio(try audioSample(firstFrame: 0), at: time))
    }

    func testQueuedPreEpochCaptureBuffersDropWithoutFailingFollowingValidStream() async throws {
        let output = Output()
        let writer = try makeWriter(output)
        XCTAssertTrue(writer.appendVideo(try videoSample(frame: 0), at: CMTime(seconds: 99.98, preferredTimescale: 48_000)))
        XCTAssertTrue(writer.appendAudio(try audioSample(firstFrame: 0), at: CMTime(seconds: 99.99, preferredTimescale: 48_000)))
        try await feed(writer, seconds: 1.5)
        try await writer.finish()
        XCTAssertTrue(output.errors.isEmpty)
        XCTAssertTrue(output.drops.contains(.video))
        XCTAssertTrue(output.drops.contains(.audio))
        XCTAssertGreaterThan(output.segments.filter { $0.kind == .media }.count, 0)
    }

    func testPreEpochTimestampAfterAcceptedFrameIsStillFatal() async throws {
        let output = Output()
        let writer = try makeWriter(output)
        XCTAssertTrue(writer.appendVideo(try videoSample(frame: 0), at: CMTime(seconds: 100, preferredTimescale: 48_000)))
        XCTAssertTrue(writer.appendVideo(try videoSample(frame: 1), at: CMTime(seconds: 99.99, preferredTimescale: 48_000)))
        do { try await writer.finish(); XCTFail("A running source must not move backwards past the epoch") }
        catch let error as LiveVideoError {
            guard case .invalidSample = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(output.errors.count, 1)
    }

    func testRejectsMismatchedVideoFormatBeforePassingItToEncoder() async throws {
        let output = Output()
        let writer = try makeWriter(output)
        XCTAssertTrue(writer.appendVideo(try videoSample(frame: 0, width: 320), at: CMTime(seconds: 100, preferredTimescale: 48_000)))
        do {
            try await writer.finish()
            XCTFail("An incorrectly sized frame must fail the writer")
        } catch let error as LiveVideoError {
            guard case .invalidSample = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(output.segments.isEmpty)
        XCTAssertEqual(output.errors.count, 1)
    }

    func testRejectsAudioFormatChangeAndInvalidEpoch() async throws {
        let output = Output()
        XCTAssertThrowsError(try FragmentedMP4Writer(configuration: configuration(), epoch: .invalid,
                                                    onSegment: { output.segment($0) },
                                                    onFailure: { output.failure($0) }, onDrop: { output.drop($0) }))
        let writer = try makeWriter(output)
        XCTAssertTrue(writer.appendAudio(try audioSample(firstFrame: 0, sampleRate: 44_100), at: CMTime(seconds: 100, preferredTimescale: 48_000)))
        do {
            try await writer.finish()
            XCTFail("An unexpected PCM sample rate must fail the writer")
        } catch let error as LiveVideoError {
            guard case .invalidSample = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(output.errors.count, 1)
    }

    func testRejectsOverlappingPCMBuffers() async throws {
        let output = Output()
        let writer = try makeWriter(output)
        XCTAssertTrue(writer.appendAudio(try audioSample(firstFrame: 0), at: CMTime(value: 4_800_000, timescale: 48_000)))
        XCTAssertTrue(writer.appendAudio(try audioSample(firstFrame: 512), at: CMTime(value: 4_800_512, timescale: 48_000)))
        do { try await writer.finish(); XCTFail("Overlapping PCM buffers must be rejected") }
        catch let error as LiveVideoError {
            guard case .invalidSample = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(output.errors.count, 1)
    }

    func testCancelStopsAdmissionsAndReleasesFinishWaiters() async throws {
        let output = Output()
        let writer = try makeWriter(output)
        writer.cancel()
        XCTAssertFalse(writer.appendVideo(try videoSample(frame: 0), at: CMTime(seconds: 100, preferredTimescale: 48_000)))
        do {
            try await writer.finish()
            XCTFail("A cancelled writer cannot finish successfully")
        } catch let error as LiveVideoError {
            guard case .invalidState = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(output.errors.isEmpty, "Explicit cancellation is not a capture failure callback")
        XCTAssertTrue(output.segments.isEmpty)
    }

    func testBurstAdmissionRemainsBoundedAndReportsRejectedFrames() async throws {
        let output = Output()
        let writer = try makeWriter(output, config: configuration(maxPendingSamples: 1))
        let sample = try videoSample(frame: 0)
        var rejected = 0
        for frame in 0..<500 {
            if !writer.appendVideo(sample, at: CMTime(seconds: 100 + Double(frame) / 15, preferredTimescale: 48_000)) { rejected += 1 }
        }
        XCTAssertGreaterThan(rejected, 0)
        // Drain the queue before reading callback counts; absence of audio intentionally
        // makes this stream incomplete, while testing admission independently of hardware speed.
        do { try await writer.finish(); XCTFail("Both tracks are required") } catch {}
        XCTAssertGreaterThanOrEqual(output.drops.filter { $0 == .video }.count, rejected)
    }

    private func feed(_ writer: FragmentedMP4Writer, seconds: Double) async throws {
        var videoFrame = 0
        var audioFrame = 0
        while Double(videoFrame) / 15 < seconds || Double(audioFrame) / 48_000 < seconds {
            let videoTime = Double(videoFrame) / 15
            let audioTime = Double(audioFrame) / 48_000
            if videoTime <= audioTime, videoTime < seconds {
                XCTAssertTrue(writer.appendVideo(try videoSample(frame: videoFrame), at: CMTime(seconds: 100 + videoTime, preferredTimescale: 48_000)))
                videoFrame += 1
            } else if audioTime < seconds {
                XCTAssertTrue(writer.appendAudio(try audioSample(firstFrame: audioFrame), at: CMTime(seconds: 100 + audioTime, preferredTimescale: 48_000)))
                audioFrame += 1024
            } else { break }
            // Give real hardware/software encoders time to consume samples without
            // making a three-second media fixture require three wall-clock seconds.
            try await Task.sleep(for: .milliseconds(3))
        }
    }

    private func videoSample(frame: Int, width: Int = 160) throws -> CMSampleBuffer {
        try FragmentedMP4Fixtures.video(frame: frame, width: width)
    }

    private func audioSample(firstFrame: Int, sampleRate: Double = 48_000) throws -> CMSampleBuffer {
        try FragmentedMP4Fixtures.audio(firstFrame: firstFrame, sampleRate: sampleRate)
    }
}

/// Real raw AVFoundation fixtures shared with broadcaster integration tests.
enum FragmentedMP4Fixtures {
    /// Reads real ISO-BMFF track decode timestamps, preserving the shared timeline.
    /// AVURLAsset normalizes standalone HLS fragments' tracks independently, so its
    /// track ranges alone cannot verify a configured audio synchronization offset.
    static func decodeTimes(in data: Data) throws -> [UInt32: UInt64] {
        struct Box { let type: String; let payload: Range<Int> }
        func integer(_ offset: Int, count: Int, limit: Int) throws -> UInt64 {
            guard offset >= 0, count > 0, offset + count <= limit else {
                throw LiveVideoError.invalidSample("Truncated test fragment")
            }
            return data[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        func boxes(_ range: Range<Int>) throws -> [Box] {
            var cursor = range.lowerBound
            var result: [Box] = []
            while cursor < range.upperBound {
                let size32 = try integer(cursor, count: 4, limit: range.upperBound)
                guard cursor + 8 <= range.upperBound else { throw LiveVideoError.invalidSample("Truncated test box") }
                let type = String(decoding: data[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
                let header = size32 == 1 ? 16 : 8
                let length = size32 == 1 ? try integer(cursor + 8, count: 8, limit: range.upperBound) : (size32 == 0 ? UInt64(range.upperBound - cursor) : size32)
                guard length >= header, length <= range.upperBound - cursor else { throw LiveVideoError.invalidSample("Invalid test box size") }
                let end = cursor + Int(length)
                result.append(Box(type: type, payload: (cursor + header)..<end))
                cursor = end
            }
            return result
        }
        var result: [UInt32: UInt64] = [:]
        for moof in try boxes(0..<data.count) where moof.type == "moof" {
            for traf in try boxes(moof.payload) where traf.type == "traf" {
                let children = try boxes(traf.payload)
                guard let tfhd = children.first(where: { $0.type == "tfhd" }),
                      let tfdt = children.first(where: { $0.type == "tfdt" }) else { continue }
                let track = try integer(tfhd.payload.lowerBound + 4, count: 4, limit: tfhd.payload.upperBound)
                let version = try integer(tfdt.payload.lowerBound, count: 1, limit: tfdt.payload.upperBound)
                let time = try integer(tfdt.payload.lowerBound + 4, count: version == 1 ? 8 : 4, limit: tfdt.payload.upperBound)
                result[UInt32(track)] = time
            }
        }
        return result
    }

    static func video(frame: Int, width: Int = 160) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, 96, kCVPixelFormatType_32BGRA,
                                          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let pointer = CVPixelBufferGetBaseAddress(buffer) {
            memset(pointer, Int32((frame * 7) % 255), CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 15), presentationTimeStamp: CMTime(value: Int64(frame), timescale: 15), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                               formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    static func audio(firstFrame: Int, sampleRate: Double = 48_000) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
        let frameCount = 1024
        var values = [Int16](repeating: 0, count: frameCount * 2)
        for frame in 0..<frameCount {
            let value = Int16(sin(2 * .pi * 440 * Double(firstFrame + frame) / sampleRate) * 6000)
            values[frame * 2] = value
            values[frame * 2 + 1] = value
        }
        var block: CMBlockBuffer?
        let byteCount = values.count * MemoryLayout<Int16>.size
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block), noErr)
        let blockBuffer = try XCTUnwrap(block)
        XCTAssertEqual(values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount) }, noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: CMTime(value: Int64(firstFrame), timescale: Int32(sampleRate)), decodeTimeStamp: .invalid)
        var sampleSize = 4
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: try XCTUnwrap(format), sampleCount: frameCount, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}

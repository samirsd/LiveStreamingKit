import XCTest
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@testable import LiveStreamingVideo

final class LiveVideoDurationTests: XCTestCase, @unchecked Sendable {
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [LiveVideoSegment] = []
        private var failures: [LiveVideoError] = []
        private var dropped = 0
        func append(_ segment: LiveVideoSegment) { lock.withLock { values.append(segment) } }
        func fail(_ error: LiveVideoError) { lock.withLock { failures.append(error) } }
        func drop(_: LiveVideoMediaType) { lock.withLock { dropped += 1 } }
        var snapshot: ([LiveVideoSegment], [LiveVideoError], Int) { lock.withLock { (values, failures, dropped) } }
    }

    func testRealLongEncoderDurationsMatchEncodedPacketSpanForAllAudioOffsets() async throws {
        for offset in [0.0, -0.25, 0.25] {
            let segments = try await encode(videoSeconds: 60, audioSeconds: 60, offset: offset)
            let packetSpan = try EncodedPacketTimeline(segments: segments)
            let media = segments.filter { $0.kind == .media }
            XCTAssertGreaterThanOrEqual(media.count, 30)
            XCTAssertEqual(media.map(\.sequence), Array(0..<media.count))
            XCTAssertEqual(media.reduce(0) { $0 + $1.duration }, packetSpan.duration,
                           accuracy: 1.0 / 48_000, "EXTINF must follow actual packet PTS, offset=\(offset)")
            // Verify every published prefix too: duration must not drift and then
            // be repaired only in the final segment. This expectation comes from
            // tfdt/trun bytes, independently of AVAssetSegmentReport metadata.
            for count in 1...media.count {
                let prefix = [segments[0]] + Array(media.prefix(count))
                XCTAssertEqual(media.prefix(count).reduce(0) { $0 + $1.duration },
                               try EncodedPacketTimeline(segments: prefix).duration,
                               accuracy: 1.0 / 48_000)
            }
            try await assertDecoded(segments, expectedVideoFrames: 900, expectedAudioFrames: 2_880_000)
        }
    }

    func testRealAudioOnlyTailStillAdvancesTheCommonPresentationTimeline() async throws {
        let segments = try await encode(videoSeconds: 8, audioSeconds: 10, offset: 0)
        let media = segments.filter { $0.kind == .media }
        let packets = try EncodedPacketTimeline(segments: segments)
        XCTAssertTrue(try media.contains { try EncodedPacketTimeline.trackIDs(in: $0.data) == [2] },
                      "Fixture must contain a real audio-only fragment")
        XCTAssertEqual(media.reduce(0) { $0 + $1.duration }, packets.duration, accuracy: 1.0 / 48_000)
        try await assertDecoded(segments, expectedVideoFrames: 120, expectedAudioFrames: 480_000)
    }

    func testInvalidOrNonadvancingTimingDoesNotMoveThePublishedBoundary() throws {
        var timeline = FragmentPresentationTimeline()
        func range(_ start: Int64, _ duration: Int64) -> CMTimeRange {
            CMTimeRange(start: CMTime(value: start, timescale: 48_000),
                        duration: CMTime(value: duration, timescale: 48_000))
        }
        XCTAssertThrowsError(try timeline.duration(for: []))
        XCTAssertThrowsError(try timeline.duration(for: [CMTimeRange(start: .invalid, duration: CMTime(value: 1, timescale: 1))]))
        XCTAssertThrowsError(try timeline.duration(for: [range(0, 0)]))
        XCTAssertEqual(try timeline.duration(for: [range(479_488, 96_256)]), 96_256.0 / 48_000)
        XCTAssertThrowsError(try timeline.duration(for: [range(479_488, 96_256)]))
        XCTAssertThrowsError(try timeline.duration(for: [range(479_488, 1)]))
        XCTAssertEqual(try timeline.duration(for: [range(575_744, 96_256)]), 96_256.0 / 48_000)
    }

    private func encode(videoSeconds: Double, audioSeconds: Double, offset: Double) async throws -> [LiveVideoSegment] {
        let output = Output()
        let configuration = LiveVideoConfiguration(videoWidth: 160, videoHeight: 96, framesPerSecond: 15,
            videoBitrate: 300_000, audioSampleRate: 48_000, audioChannelCount: 2,
            audioBitrate: 128_000, segmentDuration: 2, maxPendingSamples: 120, audioOffset: offset)
        let writer = try FragmentedMP4Writer(configuration: configuration,
            epoch: CMTime(seconds: 100, preferredTimescale: 48_000),
            onSegment: output.append, onFailure: output.fail, onDrop: output.drop)
        var video = 0, audio = 0
        while Double(video) / 15 < videoSeconds || Double(audio) / 48_000 < audioSeconds {
            let v = Double(video) / 15, a = Double(audio) / 48_000
            if v < videoSeconds && (v <= a || a >= audioSeconds) {
                XCTAssertTrue(writer.appendVideo(try FragmentedMP4Fixtures.video(frame: video),
                    at: CMTime(seconds: 100 + v, preferredTimescale: 48_000)))
                video += 1
            } else if a < audioSeconds {
                XCTAssertTrue(writer.appendAudio(try FragmentedMP4Fixtures.audio(firstFrame: audio),
                    at: CMTime(seconds: 100 + a, preferredTimescale: 48_000)))
                audio += 1024
            }
            // Accelerated, bounded real encoding rather than wall-clock waiting.
            try await Task.sleep(for: .milliseconds(3))
        }
        try await writer.finish()
        let (segments, errors, dropped) = output.snapshot
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(segments.first?.kind, .initialization)
        return segments
    }

    private func assertDecoded(_ segments: [LiveVideoSegment], expectedVideoFrames: Int, expectedAudioFrames: Int) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("duration-encoder-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try segments.reduce(into: Data()) { $0.append($1.data) }.write(to: url, options: .withoutOverwriting)
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let video = try XCTUnwrap(videoTracks.first)
        let audio = try XCTUnwrap(audioTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let pixels = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let pcm = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        reader.add(pixels); reader.add(pcm)
        XCTAssertTrue(reader.startReading())
        var frames = 0, audioFrames = 0
        while pixels.copyNextSampleBuffer() != nil { frames += 1 }
        while let sample = pcm.copyNextSampleBuffer() { audioFrames += CMSampleBufferGetNumSamples(sample) }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(frames, expectedVideoFrames)
        XCTAssertGreaterThanOrEqual(audioFrames, expectedAudioFrames)
        // AAC priming/padding adds complete 1024-frame packets; source samples
        // must all remain present rather than silently losing a boundary packet.
        XCTAssertLessThanOrEqual(audioFrames, expectedAudioFrames + 4096)
    }
}

/// Independent ISO-BMFF packet-clock reader. No AVAssetSegmentReport durations
/// or production timeline calculation are used to establish the expected span.
private struct EncodedPacketTimeline {
    private struct Box { let type: String; let payload: Range<Int> }
    let duration: Double

    private static func integer(_ data: Data, _ offset: Int, _ count: Int, _ end: Int) throws -> UInt64 {
        guard offset >= 0, count > 0, offset + count <= end else { throw LiveVideoError.invalidSample("Truncated fixture") }
        return data[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func boxes(_ data: Data, _ range: Range<Int>) throws -> [Box] {
        var cursor = range.lowerBound, result: [Box] = []
        while cursor < range.upperBound {
            let length32 = try integer(data, cursor, 4, range.upperBound)
            let header = length32 == 1 ? 16 : 8
            let length = length32 == 1 ? try integer(data, cursor + 8, 8, range.upperBound) : (length32 == 0 ? UInt64(range.upperBound - cursor) : length32)
            guard length >= header, length <= range.upperBound - cursor else { throw LiveVideoError.invalidSample("Invalid fixture box") }
            let type = String(decoding: data[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
            result.append(Box(type: type, payload: (cursor + header)..<(cursor + Int(length))))
            cursor += Int(length)
        }
        return result
    }

    static func trackIDs(in data: Data) throws -> Set<UInt32> {
        var ids: Set<UInt32> = []
        for moof in try boxes(data, 0..<data.count) where moof.type == "moof" {
            for traf in try boxes(data, moof.payload) where traf.type == "traf" {
                for header in try boxes(data, traf.payload) where header.type == "tfhd" {
                    ids.insert(UInt32(try integer(data, header.payload.lowerBound + 4, 4, header.payload.upperBound)))
                }
            }
        }
        return ids
    }

    init(segments: [LiveVideoSegment]) throws {
        let initialization = try XCTUnwrap(segments.first { $0.kind == .initialization }).data
        var timescales: [UInt32: Int32] = [:], defaults: [UInt32: UInt64] = [:]
        for moov in try Self.boxes(initialization, 0..<initialization.count) where moov.type == "moov" {
            for child in try Self.boxes(initialization, moov.payload) {
                if child.type == "trak" {
                    let boxes = try Self.boxes(initialization, child.payload)
                    let tkhd = try XCTUnwrap(boxes.first { $0.type == "tkhd" })
                    let version = try Self.integer(initialization, tkhd.payload.lowerBound, 1, tkhd.payload.upperBound)
                    let id = UInt32(try Self.integer(initialization, tkhd.payload.lowerBound + (version == 1 ? 20 : 12), 4, tkhd.payload.upperBound))
                    let mdia = try XCTUnwrap(boxes.first { $0.type == "mdia" })
                    let mdhd = try XCTUnwrap(try Self.boxes(initialization, mdia.payload).first { $0.type == "mdhd" })
                    let mdhdVersion = try Self.integer(initialization, mdhd.payload.lowerBound, 1, mdhd.payload.upperBound)
                    timescales[id] = Int32(try Self.integer(initialization, mdhd.payload.lowerBound + (mdhdVersion == 1 ? 20 : 12), 4, mdhd.payload.upperBound))
                } else if child.type == "mvex" {
                    for trex in try Self.boxes(initialization, child.payload) where trex.type == "trex" {
                        let id = UInt32(try Self.integer(initialization, trex.payload.lowerBound + 4, 4, trex.payload.upperBound))
                        defaults[id] = try Self.integer(initialization, trex.payload.lowerBound + 12, 4, trex.payload.upperBound)
                    }
                }
            }
        }
        var earliest: CMTime?, latest: CMTime?
        for segment in segments where segment.kind == .media {
            let data = segment.data
            for moof in try Self.boxes(data, 0..<data.count) where moof.type == "moof" {
                for traf in try Self.boxes(data, moof.payload) where traf.type == "traf" {
                    let children = try Self.boxes(data, traf.payload)
                    let tfhd = try XCTUnwrap(children.first { $0.type == "tfhd" })
                    let id = UInt32(try Self.integer(data, tfhd.payload.lowerBound + 4, 4, tfhd.payload.upperBound))
                    let scale = try XCTUnwrap(timescales[id]); XCTAssertGreaterThan(scale, 0)
                    let flags = try Self.integer(data, tfhd.payload.lowerBound + 1, 3, tfhd.payload.upperBound)
                    var cursor = tfhd.payload.lowerBound + 8
                    if flags & 1 != 0 { cursor += 8 }; if flags & 2 != 0 { cursor += 4 }
                    let fallback = flags & 8 != 0 ? try Self.integer(data, cursor, 4, tfhd.payload.upperBound) : defaults[id, default: 0]
                    let tfdt = try XCTUnwrap(children.first { $0.type == "tfdt" })
                    let version = try Self.integer(data, tfdt.payload.lowerBound, 1, tfdt.payload.upperBound)
                    var decode = try Self.integer(data, tfdt.payload.lowerBound + 4, version == 1 ? 8 : 4, tfdt.payload.upperBound)
                    for trun in children where trun.type == "trun" {
                        let version = try Self.integer(data, trun.payload.lowerBound, 1, trun.payload.upperBound)
                        let flags = try Self.integer(data, trun.payload.lowerBound + 1, 3, trun.payload.upperBound)
                        let count = try Self.integer(data, trun.payload.lowerBound + 4, 4, trun.payload.upperBound)
                        cursor = trun.payload.lowerBound + 8
                        if flags & 1 != 0 { cursor += 4 }; if flags & 4 != 0 { cursor += 4 }
                        for _ in 0..<count {
                            let duration = flags & 0x100 != 0 ? try Self.integer(data, cursor, 4, trun.payload.upperBound) : fallback
                            if flags & 0x100 != 0 { cursor += 4 }; if flags & 0x200 != 0 { cursor += 4 }; if flags & 0x400 != 0 { cursor += 4 }
                            var composition: Int64 = 0
                            if flags & 0x800 != 0 {
                                let raw = UInt32(try Self.integer(data, cursor, 4, trun.payload.upperBound)); cursor += 4
                                composition = version == 1 ? Int64(Int32(bitPattern: raw)) : Int64(raw)
                            }
                            XCTAssertGreaterThan(duration, 0)
                            let start = CMTime(value: Int64(decode) + composition, timescale: scale)
                            let end = start + CMTime(value: Int64(duration), timescale: scale)
                            if earliest == nil || CMTimeCompare(start, earliest!) < 0 { earliest = start }
                            if latest == nil || CMTimeCompare(end, latest!) > 0 { latest = end }
                            decode += duration
                        }
                    }
                }
            }
        }
        self.duration = CMTimeSubtract(try XCTUnwrap(latest), try XCTUnwrap(earliest)).seconds
    }
}

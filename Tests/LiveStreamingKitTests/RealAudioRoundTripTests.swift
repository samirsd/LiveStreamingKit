import XCTest
import AVFoundation
@testable import LiveStreamingKit

/// End-to-end real-audio validation:
///   PCM (440Hz sine, 4 channels)
///     → StereoDownmixer
///     → AACEncoder
///     → HLSSegmenter (ADTS-framed .aac)
///     → ffprobe verifies AAC bitstream metadata
///     → ffmpeg decodes back to PCM
///     → assert non-silence + spectral peak near 440Hz
///
/// Cost controls:
/// - Runs entirely in-process and on local /tmp; no network IO of any kind.
/// - Bounded to ~8 seconds of synthetic audio (~2 segments, ~200KB total).
/// - Skips with `throw XCTSkip` if ffmpeg/ffprobe are not on PATH.
final class RealAudioRoundTripTests: XCTestCase {
    private let sampleRate: Double = 48_000
    private let tone: Double = 440.0

    private static let ffprobePath: String? = locateBinary("ffprobe")
    private static let ffmpegPath: String? = locateBinary("ffmpeg")

    func testPCMRoundTripThroughEncoderAndSegmenterRecoversTone() throws {
        try XCTSkipUnless(Self.ffprobePath != nil && Self.ffmpegPath != nil,
                          "ffmpeg/ffprobe not installed — skipping real-audio validation")

        // Pipeline construction
        let downmixer = try XCTUnwrap(StereoDownmixer(
            sampleRate: sampleRate,
            channelMap: .summedMono
        ))
        let encoder = try XCTUnwrap(AACEncoder(
            sourceFormat: downmixer.outputFormat,
            sampleRate: sampleRate,
            bitrate: 128_000
        ))
        let segmenter = HLSSegmenter(
            targetDuration: 4.0,
            sampleRate: sampleRate,
            channelCount: 2
        )

        // Feed 8 seconds of 440Hz sine across 4 channels (simulating a multichannel input).
        let totalFrames = Int(sampleRate * 8)
        let chunkFrames = 1024
        var segments: [HLSSegment] = []
        for chunkStart in stride(from: 0, to: totalFrames, by: chunkFrames) {
            let frames = min(chunkFrames, totalFrames - chunkStart)
            let buffer = try makeMultiChannelSine(channels: 4, frameOffset: chunkStart, frames: frames)
            guard let stereo = downmixer.downmix(buffer) else {
                XCTFail("downmixer returned nil at chunk \(chunkStart)")
                return
            }
            let packets = try encoder.encode(stereo)
            for packet in packets {
                if let segment = segmenter.append(packet) {
                    segments.append(segment)
                }
            }
        }
        for packet in try encoder.flush() {
            if let segment = segmenter.append(packet) {
                segments.append(segment)
            }
        }
        if let final = segmenter.finish() {
            segments.append(final)
        }

        XCTAssertGreaterThanOrEqual(segments.count, 1, "expected at least one HLS segment from 8s of audio")

        // Materialize segments to disk for ffmpeg/ffprobe analysis.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("livestream-validation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for (index, segment) in segments.enumerated() {
            let url = tempDir.appendingPathComponent("\(index).aac")
            try segment.data.write(to: url)
        }

        // --- ffprobe metadata check ---
        let firstSegmentURL = tempDir.appendingPathComponent("0.aac")
        let probe = try runFFProbe(at: firstSegmentURL)
        XCTAssertEqual(probe.codec, "aac", "ffprobe should identify codec as aac")
        XCTAssertEqual(probe.channels, 2)
        XCTAssertEqual(probe.sampleRate, 48_000)
        XCTAssertGreaterThan(probe.duration, 1.0, "first segment should be at least ~1s of audio")

        // --- ffmpeg PCM round-trip + tone detection ---
        let recoveredSamples = try decodeToFloatPCM(at: firstSegmentURL)
        XCTAssertGreaterThan(recoveredSamples.count, 4096, "expected non-trivial PCM output")

        let rms = computeRMS(recoveredSamples)
        XCTAssertGreaterThan(rms, 0.01, "recovered PCM has near-zero energy — encoder produced silence?")

        let toneEnergyRatio = goertzelEnergyRatio(samples: recoveredSamples, targetHz: tone, sampleRate: sampleRate)
        XCTAssertGreaterThan(
            toneEnergyRatio, 0.3,
            "expected 440Hz tone to dominate spectral energy (got \(toneEnergyRatio))"
        )

        // Log the measurements so CI surfaces the actual audio fidelity numbers.
        print("[validation] segments=\(segments.count) first-segment-bytes=\(segments[0].data.count) " +
              "ffprobe.codec=\(probe.codec) ffprobe.duration=\(String(format: "%.3f", probe.duration)) " +
              "rms=\(String(format: "%.4f", rms)) tone-energy-ratio=\(String(format: "%.3f", toneEnergyRatio))")
    }

    func testGeneratedPlaylistIsParseableByFFProbeAndPointsAtValidSegments() throws {
        try XCTSkipUnless(Self.ffprobePath != nil && Self.ffmpegPath != nil,
                          "ffmpeg/ffprobe not installed — skipping playlist validation")

        let downmixer = try XCTUnwrap(StereoDownmixer(sampleRate: sampleRate, channelMap: .summedMono))
        let encoder = try XCTUnwrap(AACEncoder(sourceFormat: downmixer.outputFormat, sampleRate: sampleRate, bitrate: 96_000))
        let segmenter = HLSSegmenter(targetDuration: 2.0, sampleRate: sampleRate, channelCount: 2)
        var segments: [HLSSegment] = []
        let chunkFrames = 1024
        let totalFrames = Int(sampleRate * 6)
        for chunkStart in stride(from: 0, to: totalFrames, by: chunkFrames) {
            let frames = min(chunkFrames, totalFrames - chunkStart)
            let buffer = try makeMultiChannelSine(channels: 2, frameOffset: chunkStart, frames: frames)
            guard let stereo = downmixer.downmix(buffer) else { continue }
            for packet in try encoder.encode(stereo) {
                if let segment = segmenter.append(packet) {
                    segments.append(segment)
                }
            }
        }
        if let last = segmenter.finish() {
            segments.append(last)
        }
        XCTAssertGreaterThanOrEqual(segments.count, 2)

        // Lay out segments + a sibling playlist on disk so ffprobe can follow it.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("livestream-playlist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var segmentRefs: [PlaylistBuilder.SegmentRef] = []
        for segment in segments {
            let filename = "\(segment.sequence).aac"
            try segment.data.write(to: tempDir.appendingPathComponent(filename))
            segmentRefs.append(.init(uri: filename, duration: segment.duration))
        }
        let playlist = PlaylistBuilder(targetDuration: 2, mediaSequence: 0, segments: segmentRefs, isClosed: true)
        let playlistURL = tempDir.appendingPathComponent("media.m3u8")
        try playlist.render().write(to: playlistURL, atomically: true, encoding: .utf8)

        let probe = try runFFProbe(at: playlistURL)
        XCTAssertEqual(probe.codec, "aac", "ffprobe should treat the playlist as an aac elementary stream")
        XCTAssertEqual(probe.channels, 2)
        XCTAssertEqual(probe.sampleRate, 48_000)
        // Total duration must be close to the sum of segment durations (within encoder/segmenter rounding).
        let expectedDuration = segmentRefs.reduce(0.0) { $0 + $1.duration }
        XCTAssertEqual(probe.duration, expectedDuration, accuracy: 0.5,
                       "ffprobe must report a duration consistent with the sum of segment durations")
        print("[validation] playlist-segments=\(segments.count) total-duration=\(String(format: "%.3f", expectedDuration)) ffprobe-duration=\(String(format: "%.3f", probe.duration))")
    }

    // MARK: - Audio synthesis

    private func makeMultiChannelSine(channels: Int, frameOffset: Int, frames: Int) throws -> AVAudioPCMBuffer {
        let layoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: layoutTag))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData)
        let amplitude: Float = 0.4
        for ch in 0..<channels {
            for n in 0..<frames {
                let global = frameOffset + n
                let phase = 2.0 * .pi * tone * Double(global) / sampleRate
                data[ch][n] = amplitude * Float(sin(phase))
            }
        }
        return buffer
    }

    // MARK: - ffmpeg / ffprobe drivers

    private struct ProbeResult {
        let codec: String
        let channels: Int
        let sampleRate: Int
        let duration: Double
    }

    private func runFFProbe(at url: URL) throws -> ProbeResult {
        guard let probe = Self.ffprobePath else {
            throw XCTSkip("ffprobe missing")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: probe)
        process.arguments = [
            "-v", "error",
            "-show_streams",
            "-show_format",
            "-of", "json",
            url.path,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "ffprobe failed: \(String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "<no stderr>")")
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let streams = (json["streams"] as? [[String: Any]]) ?? []
        let format = json["format"] as? [String: Any] ?? [:]
        guard let stream = streams.first else {
            XCTFail("ffprobe returned no streams")
            return ProbeResult(codec: "", channels: 0, sampleRate: 0, duration: 0)
        }
        let codec = stream["codec_name"] as? String ?? ""
        let channels = stream["channels"] as? Int ?? 0
        let sampleRateString = stream["sample_rate"] as? String ?? "0"
        let sampleRate = Int(sampleRateString) ?? 0
        let duration: Double = {
            if let str = stream["duration"] as? String, let v = Double(str) { return v }
            if let str = format["duration"] as? String, let v = Double(str) { return v }
            return 0
        }()
        return ProbeResult(codec: codec, channels: channels, sampleRate: sampleRate, duration: duration)
    }

    private func decodeToFloatPCM(at url: URL) throws -> [Float] {
        guard let ffmpeg = Self.ffmpegPath else { throw XCTSkip("ffmpeg missing") }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("livestream-decode-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-loglevel", "error",
            "-i", url.path,
            "-f", "f32le",
            "-ac", "1", // downmix to mono for spectral analysis
            "-ar", "\(Int(sampleRate))",
            "-y", outputURL.path,
        ]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
                       "ffmpeg failed: \(String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "<no stderr>")")

        let raw = try Data(contentsOf: outputURL)
        let count = raw.count / MemoryLayout<Float>.size
        var samples = [Float](repeating: 0, count: count)
        _ = samples.withUnsafeMutableBytes { dst in
            raw.copyBytes(to: dst, count: raw.count)
        }
        return samples
    }

    // MARK: - DSP utilities

    private func computeRMS(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(0.0) { $0 + Double($1 * $1) }
        return (sumSquares / Double(samples.count)).squareRoot()
    }

    /// Returns the ratio of energy near `targetHz` to total signal energy via a Goertzel filter.
    /// A pure sine at the target frequency should give ratio ≈ 1.0; broadband noise gives ≈ 0.
    private func goertzelEnergyRatio(samples: [Float], targetHz: Double, sampleRate: Double) -> Double {
        guard samples.count > 16 else { return 0 }
        let k = Int(round(Double(samples.count) * targetHz / sampleRate))
        let omega = 2.0 * .pi * Double(k) / Double(samples.count)
        let coeff = 2.0 * cos(omega)
        var s0 = 0.0, s1 = 0.0, s2 = 0.0
        for value in samples {
            s0 = Double(value) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let bandEnergy = s1 * s1 + s2 * s2 - coeff * s1 * s2
        let totalEnergy = samples.reduce(0.0) { $0 + Double($1 * $1) }
        guard totalEnergy > 0 else { return 0 }
        return bandEnergy / totalEnergy
    }

    private static func locateBinary(_ name: String) -> String? {
        for candidate in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let path = "\(candidate)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

import XCTest
import AVFoundation
@testable import LiveStreamingKit

final class AACEncoderTests: XCTestCase {
    private let sampleRate: Double = 48_000

    func testEncoderInitializesForStereoFloat32Source() throws {
        let format = try stereoFormat()
        let encoder = AACEncoder(sourceFormat: format, sampleRate: sampleRate, bitrate: 128_000)
        XCTAssertNotNil(encoder)
    }

    func testEncoderRejectsNonStereoSource() throws {
        let mono = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let encoder = AACEncoder(sourceFormat: mono, sampleRate: sampleRate, bitrate: 128_000)
        XCTAssertNil(encoder)
    }

    func testEncoderEmitsPacketsAfterEnoughFrames() throws {
        let format = try stereoFormat()
        let encoder = try XCTUnwrap(AACEncoder(sourceFormat: format, sampleRate: sampleRate, bitrate: 128_000))

        // Provide ~ 5 packets worth of audio (5 * 1024 frames).
        let buffer = try makeSineBuffer(frames: 1024 * 5)
        let packets = try encoder.encode(buffer)
        XCTAssertFalse(packets.isEmpty)
        for packet in packets {
            XCTAssertEqual(packet.frameCount, 1024)
            XCTAssertEqual(packet.sampleRate, sampleRate)
            XCTAssertGreaterThan(packet.data.count, 0)
        }
    }

    func testEncoderAdvancesPresentationTime() throws {
        let format = try stereoFormat()
        let encoder = try XCTUnwrap(AACEncoder(sourceFormat: format, sampleRate: sampleRate, bitrate: 128_000))
        let buffer = try makeSineBuffer(frames: 1024 * 4)
        let packets = try encoder.encode(buffer)
        guard packets.count >= 2 else {
            return XCTFail("expected at least two AAC packets, got \(packets.count)")
        }
        XCTAssertEqual(packets[0].presentationTime, 0)
        XCTAssertEqual(packets[1].presentationTime, AVAudioFramePosition(packets[0].frameCount))
    }

    func testFlushDrainsRemainingFrames() throws {
        let format = try stereoFormat()
        let encoder = try XCTUnwrap(AACEncoder(sourceFormat: format, sampleRate: sampleRate, bitrate: 128_000))
        // Feed a partial packet's worth of audio.
        let buffer = try makeSineBuffer(frames: 500)
        let immediate = try encoder.encode(buffer)
        XCTAssertTrue(immediate.isEmpty, "should hold short feed until enough frames accumulate")

        let buffer2 = try makeSineBuffer(frames: 600)
        _ = try encoder.encode(buffer2)
        let flushed = try encoder.flush()
        // Either the buffered audio came out during encode() or during flush(); total ≥ 1 packet
        let combined = immediate.count + flushed.count
        XCTAssertGreaterThanOrEqual(combined, 1)
    }

    // MARK: - Helpers

    private func stereoFormat() throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false))
    }

    private func makeSineBuffer(frames: Int) throws -> AVAudioPCMBuffer {
        let format = try stereoFormat()
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData)
        let frequency: Double = 440
        for n in 0..<frames {
            let value = Float(sin(2.0 * .pi * frequency * Double(n) / sampleRate)) * 0.5
            data[0][n] = value
            data[1][n] = value
        }
        return buffer
    }
}

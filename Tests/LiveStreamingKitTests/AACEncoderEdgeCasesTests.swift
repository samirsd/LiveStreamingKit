import XCTest
import AVFoundation
@testable import LiveStreamingKit

final class AACEncoderEdgeCasesTests: XCTestCase {
    private let sampleRate: Double = 48_000

    func testEncoderRejects44100MonoSource() throws {
        let mono = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
        XCTAssertNil(AACEncoder(sourceFormat: mono, sampleRate: 44_100, bitrate: 128_000))
    }

    func testEncoderInitializesAt44100Stereo() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false))
        XCTAssertNotNil(AACEncoder(sourceFormat: format, sampleRate: 44_100, bitrate: 96_000))
    }

    func testEncoderSampleRateRatioReflectsTargetVsSource() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let encoder = try XCTUnwrap(AACEncoder(sourceFormat: format, sampleRate: 48_000, bitrate: 128_000))
        XCTAssertEqual(encoder.sampleRateRatio, 1.0, accuracy: 0.001)
    }

    func testEncoderEmitsContinuousPresentationTimes() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false))
        let encoder = try XCTUnwrap(AACEncoder(sourceFormat: format, sampleRate: sampleRate, bitrate: 128_000))
        let totalFrames = 1024 * 8
        let buffer = try makeSineBuffer(frames: totalFrames)
        let packets = try encoder.encode(buffer)
        XCTAssertGreaterThan(packets.count, 4)
        for (index, packet) in packets.enumerated() {
            let expected = AVAudioFramePosition(index * 1024)
            XCTAssertEqual(packet.presentationTime, expected)
        }
    }

    func testEncoderConsumesIncrementallyAcrossEncodeCalls() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false))
        let encoder = try XCTUnwrap(AACEncoder(sourceFormat: format, sampleRate: sampleRate, bitrate: 128_000))
        var totalPackets = 0
        // 4 calls of 1024 frames each → ~4 packets total
        for _ in 0..<4 {
            let chunk = try makeSineBuffer(frames: 1024)
            totalPackets += try encoder.encode(chunk).count
        }
        XCTAssertEqual(totalPackets, 4)
    }

    func testFlushAfterEvenMultipleProducesAtMostOneLeftoverPacket() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false))
        let encoder = try XCTUnwrap(AACEncoder(sourceFormat: format, sampleRate: sampleRate, bitrate: 128_000))
        // AAC encoders carry a priming sample window; feeding an even multiple of
        // 1024 frames may leave one packet's worth held until flush.
        let chunkCount = 8
        var emittedDuringEncode = 0
        for _ in 0..<chunkCount {
            emittedDuringEncode += try encoder.encode(makeSineBuffer(frames: 1024)).count
        }
        let flushed = try encoder.flush()
        XCTAssertLessThanOrEqual(flushed.count, 1, "flush should drain at most one buffered packet")
        XCTAssertGreaterThanOrEqual(emittedDuringEncode + flushed.count, chunkCount - 1)
    }

    func testEncodedPacketDurationDerivesFromFrameCountAndSampleRate() {
        let packet = EncodedAACPacket(data: Data([0]), frameCount: 1024, presentationTime: 0, sampleRate: 48_000)
        XCTAssertEqual(packet.duration, 1024.0 / 48_000.0, accuracy: 1e-9)
    }

    func testEncodedAACPacketEquality() {
        let a = EncodedAACPacket(data: Data([1]), frameCount: 1024, presentationTime: 0, sampleRate: 48_000)
        let b = EncodedAACPacket(data: Data([1]), frameCount: 1024, presentationTime: 0, sampleRate: 48_000)
        let c = EncodedAACPacket(data: Data([2]), frameCount: 1024, presentationTime: 0, sampleRate: 48_000)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testEncoderRejectsChannelCountMismatchAtEncodeTime() throws {
        let stereoFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false))
        let encoder = try XCTUnwrap(AACEncoder(sourceFormat: stereoFormat, sampleRate: sampleRate, bitrate: 128_000))
        let monoFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let monoBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 1024))
        monoBuffer.frameLength = 1024
        XCTAssertThrowsError(try encoder.encode(monoBuffer)) { error in
            guard case LiveStreamError.encoderFailed(let message) = error else {
                XCTFail("expected encoderFailed, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("channel"))
        }
    }

    // MARK: - Helpers

    private func makeSineBuffer(frames: Int) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false))
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

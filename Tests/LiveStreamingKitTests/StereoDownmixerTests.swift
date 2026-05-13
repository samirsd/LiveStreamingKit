import XCTest
import AVFoundation
@testable import LiveStreamingKit

final class StereoDownmixerTests: XCTestCase {
    private let sampleRate: Double = 48_000

    func testInterleavedStereoMixdownSplitsEvenAndOddChannels() throws {
        let mixer = try XCTUnwrap(StereoDownmixer(sampleRate: sampleRate, channelMap: .interleavedStereoMixdown))
        let buffer = try makeBuffer(channels: 4, frames: 8, samples: [
            [1, 1, 1, 1, 1, 1, 1, 1],
            [-1, -1, -1, -1, -1, -1, -1, -1],
            [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5],
            [-0.5, -0.5, -0.5, -0.5, -0.5, -0.5, -0.5, -0.5],
        ])

        let result = try XCTUnwrap(mixer.downmix(buffer))
        XCTAssertEqual(result.format.channelCount, 2)
        XCTAssertEqual(Int(result.frameLength), 8)

        let left = channelArray(result, channel: 0)
        let right = channelArray(result, channel: 1)
        // even channels (0, 2) split between left bus: ((1) + (0.5)) / 2 = 0.75
        XCTAssertEqual(try XCTUnwrap(left.first), 0.75, accuracy: 0.0001)
        // odd channels (1, 3) split between right bus: ((-1) + (-0.5)) / 2 = -0.75
        XCTAssertEqual(try XCTUnwrap(right.first), -0.75, accuracy: 0.0001)
    }

    func testSummedMonoPlacesIdenticalContentOnBothChannels() throws {
        let mixer = try XCTUnwrap(StereoDownmixer(sampleRate: sampleRate, channelMap: .summedMono))
        let buffer = try makeBuffer(channels: 3, frames: 4, samples: [
            [0.2, 0.2, 0.2, 0.2],
            [0.4, 0.4, 0.4, 0.4],
            [0.6, 0.6, 0.6, 0.6],
        ])

        let result = try XCTUnwrap(mixer.downmix(buffer))
        let left = channelArray(result, channel: 0)
        let right = channelArray(result, channel: 1)
        XCTAssertEqual(left, right)
        // (0.2 + 0.4 + 0.6) / 3 * 0.707 ≈ 0.2827
        XCTAssertEqual(left.first ?? 0, 0.2827, accuracy: 0.001)
    }

    func testExplicitChannelMapHonorsRouting() throws {
        let mixer = try XCTUnwrap(StereoDownmixer(sampleRate: sampleRate, channelMap: .explicit(left: [2], right: [0])))
        let buffer = try makeBuffer(channels: 3, frames: 2, samples: [
            [0.1, 0.1],
            [0.2, 0.2],
            [0.3, 0.3],
        ])
        let result = try XCTUnwrap(mixer.downmix(buffer))
        XCTAssertEqual(channelArray(result, channel: 0).first ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(channelArray(result, channel: 1).first ?? 0, 0.1, accuracy: 0.0001)
    }

    func testDownmixClampsToPlusMinusOne() throws {
        let mixer = try XCTUnwrap(StereoDownmixer(sampleRate: sampleRate, channelMap: .explicit(left: [0, 1], right: [0, 1])))
        let buffer = try makeBuffer(channels: 2, frames: 1, samples: [[1.0], [1.0]])
        let result = try XCTUnwrap(mixer.downmix(buffer))
        XCTAssertEqual(channelArray(result, channel: 0).first ?? 0, 1.0, accuracy: 0.0001)
    }

    func testEmptyBufferReturnsNil() {
        let mixer = StereoDownmixer(sampleRate: sampleRate, channelMap: .summedMono)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 0
        XCTAssertNil(mixer?.downmix(buffer))
    }

    // MARK: - Helpers

    private func makeBuffer(channels: Int, frames: Int, samples: [[Float]]) throws -> AVAudioPCMBuffer {
        let layoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: layoutTag))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: layout
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for ch in 0..<channels {
            for f in 0..<frames {
                data[ch][f] = samples[ch][f]
            }
        }
        return buffer
    }

    private func channelArray(_ buffer: AVAudioPCMBuffer, channel: Int) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        return (0..<frames).map { data[channel][$0] }
    }
}

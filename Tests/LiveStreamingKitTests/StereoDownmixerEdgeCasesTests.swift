import XCTest
import AVFoundation
@testable import LiveStreamingKit

final class StereoDownmixerEdgeCasesTests: XCTestCase {
    private let sampleRate: Double = 48_000

    func testMonoSourceMapsBothStereoChannelsFromTheSingleChannel() throws {
        let mixer = try XCTUnwrap(StereoDownmixer(sampleRate: sampleRate, channelMap: .summedMono))
        let buffer = try makeBuffer(channels: 1, frames: 2, samples: [[0.5, 0.5]])
        let output = try XCTUnwrap(mixer.downmix(buffer))
        XCTAssertEqual(output.format.channelCount, 2)
        let left = channelArray(output, channel: 0)
        let right = channelArray(output, channel: 1)
        XCTAssertEqual(left, right)
        // .summedMono uses gain 0.707 distributed across one channel → ~0.353
        XCTAssertEqual(try XCTUnwrap(left.first), 0.3535, accuracy: 0.001)
    }

    func testOutOfRangeExplicitChannelMapFallsBackGracefully() throws {
        // explicit map references channels that don't exist on input
        let mixer = try XCTUnwrap(StereoDownmixer(
            sampleRate: sampleRate,
            channelMap: .explicit(left: [10], right: [11])
        ))
        let buffer = try makeBuffer(channels: 2, frames: 1, samples: [[0.5], [0.5]])
        let output = try XCTUnwrap(mixer.downmix(buffer))
        // With invalid indices, no left/right weights resolve; fallback distributes
        // input uniformly: 1.0/2 * 0.5 + 1.0/2 * 0.5 = 0.5
        XCTAssertEqual(try XCTUnwrap(channelArray(output, channel: 0).first), 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(channelArray(output, channel: 1).first), 0.5, accuracy: 0.001)
    }

    func testManyChannelInputSumsViaChannelMap() throws {
        let mixer = try XCTUnwrap(StereoDownmixer(sampleRate: sampleRate, channelMap: .summedMono))
        let buffer = try makeBuffer(channels: 8, frames: 1, samples: Array(repeating: [0.125], count: 8))
        let output = try XCTUnwrap(mixer.downmix(buffer))
        // (8 * 0.125) / 8 * 0.707 = 0.0884... per side
        XCTAssertEqual(try XCTUnwrap(channelArray(output, channel: 0).first), 0.0884, accuracy: 0.002)
    }

    func testDownmixerOutputFormatIsAlwaysStereo() {
        let mixer = StereoDownmixer(sampleRate: 44_100, channelMap: .summedMono)
        XCTAssertEqual(mixer?.outputFormat.channelCount, 2)
        XCTAssertEqual(mixer?.outputFormat.sampleRate, 44_100)
    }

    func testDownmixerWithLargeFrameCountPreservesSampleCount() throws {
        let mixer = try XCTUnwrap(StereoDownmixer(sampleRate: sampleRate, channelMap: .interleavedStereoMixdown))
        let frameCount = 4096
        let samples = Array(repeating: Array(repeating: Float(0.1), count: frameCount), count: 4)
        let buffer = try makeBuffer(channels: 4, frames: frameCount, samples: samples)
        let output = try XCTUnwrap(mixer.downmix(buffer))
        XCTAssertEqual(Int(output.frameLength), frameCount)
    }

    func testEmptyWeightsFallbackToUniformMix() throws {
        // Build a map where all explicit channels miss → weights resolve to []
        let mixer = try XCTUnwrap(StereoDownmixer(
            sampleRate: sampleRate,
            channelMap: .explicit(left: [99], right: [100])
        ))
        let buffer = try makeBuffer(channels: 1, frames: 1, samples: [[1.0]])
        let output = try XCTUnwrap(mixer.downmix(buffer))
        // 1.0 input, 1 channel → fallback gain 1.0/1 = 1.0 → output 1.0 (clamped)
        XCTAssertEqual(try XCTUnwrap(channelArray(output, channel: 0).first), 1.0, accuracy: 0.001)
    }

    func testDownmixIsInvariantUnderRepeatedCalls() throws {
        let mixer = try XCTUnwrap(StereoDownmixer(sampleRate: sampleRate, channelMap: .summedMono))
        let buffer = try makeBuffer(channels: 2, frames: 16, samples: [
            Array(repeating: 0.5, count: 16),
            Array(repeating: -0.5, count: 16),
        ])
        let first = try XCTUnwrap(mixer.downmix(buffer))
        let second = try XCTUnwrap(mixer.downmix(buffer))
        XCTAssertEqual(channelArray(first, channel: 0), channelArray(second, channel: 0))
        XCTAssertEqual(channelArray(first, channel: 1), channelArray(second, channel: 1))
    }

    // MARK: - Helpers

    private func makeBuffer(channels: Int, frames: Int, samples: [[Float]]) throws -> AVAudioPCMBuffer {
        let layoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: layoutTag))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
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

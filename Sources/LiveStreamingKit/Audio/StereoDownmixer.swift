import Foundation
import AVFoundation

public struct StereoDownmixer: Sendable {
    public let outputFormat: AVAudioFormat
    private let map: ChannelMap

    public init?(sampleRate: Double, channelMap: ChannelMap) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else { return nil }
        self.outputFormat = format
        self.map = channelMap
    }

    public func downmix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0, frameCount > 0 else { return nil }

        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: buffer.frameCapacity
        ) else { return nil }
        output.frameLength = buffer.frameLength

        guard let dst = output.floatChannelData else { return nil }
        let leftWeights = resolveWeights(map.left, channelCount: channelCount)
        let rightWeights = resolveWeights(map.right, channelCount: channelCount)

        for frame in 0..<frameCount {
            var left: Float = 0
            var right: Float = 0
            for (channel, gain) in leftWeights {
                left += source[channel][frame] * gain
            }
            for (channel, gain) in rightWeights {
                right += source[channel][frame] * gain
            }
            dst[0][frame] = clamp(left)
            dst[1][frame] = clamp(right)
        }

        return output
    }

    private func resolveWeights(_ weights: [ChannelWeight], channelCount: Int) -> [(Int, Float)] {
        var resolved: [(Int, Float)] = []
        for weight in weights {
            switch weight {
            case let .channel(index, gain):
                if index >= 0, index < channelCount { resolved.append((index, gain)) }
            case let .allChannels(gain):
                let normalized = gain / Float(max(channelCount, 1))
                for index in 0..<channelCount { resolved.append((index, normalized)) }
            case let .evenChannels(gain):
                let even = Array(stride(from: 0, to: channelCount, by: 2))
                let normalized = gain / Float(max(even.count, 1))
                for index in even { resolved.append((index, normalized)) }
            case let .oddChannels(gain):
                let odd = Array(stride(from: 1, to: channelCount, by: 2))
                let normalized = gain / Float(max(odd.count, 1))
                for index in odd { resolved.append((index, normalized)) }
            }
        }
        if resolved.isEmpty, channelCount > 0 {
            let gain: Float = 1.0 / Float(channelCount)
            for index in 0..<channelCount { resolved.append((index, gain)) }
        }
        return resolved
    }

    @inline(__always)
    private func clamp(_ sample: Float) -> Float {
        if sample > 1.0 { return 1.0 }
        if sample < -1.0 { return -1.0 }
        return sample
    }
}

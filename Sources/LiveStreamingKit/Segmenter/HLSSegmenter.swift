import Foundation

public struct HLSSegment: Sendable, Equatable {
    public let sequence: Int
    public let data: Data
    public let duration: TimeInterval
    public let isFinalSegment: Bool

    public init(sequence: Int, data: Data, duration: TimeInterval, isFinalSegment: Bool = false) {
        self.sequence = sequence
        self.data = data
        self.duration = duration
        self.isFinalSegment = isFinalSegment
    }
}

public final class HLSSegmenter: @unchecked Sendable {
    public let targetDuration: TimeInterval
    public let sampleRate: Double
    public let channelCount: Int

    private var nextSequence: Int
    private var pendingData: Data
    private var pendingFrameCount: Int = 0
    private var pendingDuration: TimeInterval { Double(pendingFrameCount * AACEncoder.framesPerPacketDefault) / sampleRate }

    public init(targetDuration: TimeInterval, sampleRate: Double, channelCount: Int, startingSequence: Int = 0) {
        self.targetDuration = targetDuration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.nextSequence = startingSequence
        self.pendingData = Data()
    }

    public func append(_ packet: EncodedAACPacket) -> HLSSegment? {
        guard let framed = ADTSFraming.wrap(packet, channelCount: channelCount) else { return nil }
        pendingData.append(framed)
        pendingFrameCount += 1
        if pendingDuration >= targetDuration {
            return emitSegment(isFinal: false)
        }
        return nil
    }

    public func append(packets: [EncodedAACPacket]) -> [HLSSegment] {
        var emitted: [HLSSegment] = []
        for packet in packets {
            if let segment = append(packet) {
                emitted.append(segment)
            }
        }
        return emitted
    }

    public func finish() -> HLSSegment? {
        guard pendingFrameCount > 0 else { return nil }
        return emitSegment(isFinal: true)
    }

    private func emitSegment(isFinal: Bool) -> HLSSegment {
        let duration = pendingDuration
        let segment = HLSSegment(
            sequence: nextSequence,
            data: pendingData,
            duration: duration,
            isFinalSegment: isFinal
        )
        nextSequence += 1
        pendingData = Data()
        pendingFrameCount = 0
        return segment
    }

    public var sequenceCursor: Int { nextSequence }
}

extension AACEncoder {
    public static let framesPerPacketDefault: Int = 1024
}

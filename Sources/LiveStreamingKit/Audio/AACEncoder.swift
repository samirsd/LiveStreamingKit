import Foundation
import AVFoundation
import AudioToolbox

public struct EncodedAACPacket: Sendable, Equatable {
    public let data: Data
    public let frameCount: Int
    public let presentationTime: AVAudioFramePosition
    public let sampleRate: Double

    public var duration: TimeInterval { Double(frameCount) / sampleRate }

    public init(data: Data, frameCount: Int, presentationTime: AVAudioFramePosition, sampleRate: Double) {
        self.data = data
        self.frameCount = frameCount
        self.presentationTime = presentationTime
        self.sampleRate = sampleRate
    }
}

public final class AACEncoder: @unchecked Sendable {
    public let sourceFormat: AVAudioFormat
    public let targetSampleRate: Double
    public let targetBitrate: Int
    public let framesPerPacket: Int = 1024

    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private var pendingPCM: AVAudioPCMBuffer
    private var pendingFrameCount: AVAudioFrameCount = 0
    private var samplesEnqueued: AVAudioFramePosition = 0
    private var samplesEmitted: AVAudioFramePosition = 0

    public init?(sourceFormat: AVAudioFormat, sampleRate: Double, bitrate: Int) {
        guard sourceFormat.channelCount == 2 else { return nil }
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(1024),
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let target = AVAudioFormat(streamDescription: &description) else {
            return nil
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            return nil
        }
        converter.bitRate = bitrate
        self.sourceFormat = sourceFormat
        self.targetFormat = target
        self.targetSampleRate = sampleRate
        self.targetBitrate = bitrate
        self.converter = converter
        let capacity = AVAudioFrameCount(max(1024 * 16, 32768))
        guard let pending = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: capacity) else { return nil }
        pending.frameLength = 0
        self.pendingPCM = pending
    }

    public func encode(_ buffer: AVAudioPCMBuffer) throws -> [EncodedAACPacket] {
        guard buffer.format.channelCount == sourceFormat.channelCount else {
            throw LiveStreamError.encoderFailed("source channel count mismatch")
        }
        appendToPending(buffer)
        return try drainPackets(flush: false)
    }

    public func flush() throws -> [EncodedAACPacket] {
        try drainPackets(flush: true)
    }

    public var sampleRateRatio: Double {
        targetSampleRate / sourceFormat.sampleRate
    }

    private func appendToPending(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let availableCapacity = Int(pendingPCM.frameCapacity) - Int(pendingFrameCount)
        if frames > availableCapacity {
            growPendingBuffer(toAccommodateAdditional: frames)
        }
        guard let src = buffer.floatChannelData, let dst = pendingPCM.floatChannelData else { return }
        let channelCount = Int(sourceFormat.channelCount)
        let offset = Int(pendingFrameCount)
        for channel in 0..<channelCount {
            memcpy(
                dst[channel].advanced(by: offset),
                src[channel],
                frames * MemoryLayout<Float>.size
            )
        }
        pendingFrameCount += AVAudioFrameCount(frames)
        pendingPCM.frameLength = pendingFrameCount
        samplesEnqueued += AVAudioFramePosition(frames)
    }

    private func growPendingBuffer(toAccommodateAdditional extra: Int) {
        let needed = Int(pendingFrameCount) + extra
        var newCapacity = Int(pendingPCM.frameCapacity)
        while newCapacity < needed { newCapacity *= 2 }
        guard let larger = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(newCapacity)) else { return }
        if pendingFrameCount > 0, let src = pendingPCM.floatChannelData, let dst = larger.floatChannelData {
            let channelCount = Int(sourceFormat.channelCount)
            for channel in 0..<channelCount {
                memcpy(dst[channel], src[channel], Int(pendingFrameCount) * MemoryLayout<Float>.size)
            }
        }
        larger.frameLength = pendingFrameCount
        pendingPCM = larger
    }

    private func drainPendingFrames(into target: AVAudioPCMBuffer, framesNeeded: AVAudioFrameCount) -> AVAudioFrameCount {
        let available = pendingFrameCount
        let toCopy = min(framesNeeded, available)
        guard toCopy > 0 else {
            target.frameLength = 0
            return 0
        }
        guard let src = pendingPCM.floatChannelData, let dst = target.floatChannelData else {
            target.frameLength = 0
            return 0
        }
        let channelCount = Int(sourceFormat.channelCount)
        for channel in 0..<channelCount {
            memcpy(dst[channel], src[channel], Int(toCopy) * MemoryLayout<Float>.size)
        }
        target.frameLength = toCopy

        let remaining = available - toCopy
        if remaining > 0 {
            for channel in 0..<channelCount {
                memmove(
                    src[channel],
                    src[channel].advanced(by: Int(toCopy)),
                    Int(remaining) * MemoryLayout<Float>.size
                )
            }
        }
        pendingFrameCount = remaining
        pendingPCM.frameLength = remaining
        return toCopy
    }

    private func drainPackets(flush: Bool) throws -> [EncodedAACPacket] {
        var packets: [EncodedAACPacket] = []
        var endOfStreamFed = false

        // Determine how many input frames map to one output packet.
        let inputFramesPerPacket = AVAudioFrameCount(
            (Double(framesPerPacket) / sampleRateRatio).rounded(.toNearestOrEven)
        )

        while true {
            if !flush && pendingFrameCount < inputFramesPerPacket { break }
            if flush && pendingFrameCount == 0 && endOfStreamFed { break }

            let output = AVAudioCompressedBuffer(
                format: targetFormat,
                packetCapacity: 1,
                maximumPacketSize: 4096
            )

            var inputError: NSError?
            let status = converter.convert(to: output, error: &inputError) { [weak self] requested, status in
                guard let self else {
                    status.pointee = .endOfStream
                    return nil
                }
                let needed = AVAudioFrameCount(requested)
                if self.pendingFrameCount == 0 {
                    if flush {
                        status.pointee = .endOfStream
                        endOfStreamFed = true
                        return nil
                    }
                    status.pointee = .noDataNow
                    return nil
                }
                guard let chunk = AVAudioPCMBuffer(pcmFormat: self.sourceFormat, frameCapacity: needed) else {
                    status.pointee = .endOfStream
                    return nil
                }
                let copied = self.drainPendingFrames(into: chunk, framesNeeded: needed)
                guard copied > 0 else {
                    if flush {
                        status.pointee = .endOfStream
                        endOfStreamFed = true
                        return nil
                    }
                    status.pointee = .noDataNow
                    return nil
                }
                status.pointee = .haveData
                return chunk
            }

            if let error = inputError {
                throw LiveStreamError.encoderFailed(error.localizedDescription)
            }
            switch status {
            case .haveData:
                if let packetData = extractPacketData(from: output) {
                    let frames = framesPerPacket
                    let packet = EncodedAACPacket(
                        data: packetData,
                        frameCount: frames,
                        presentationTime: samplesEmitted,
                        sampleRate: targetSampleRate
                    )
                    samplesEmitted += AVAudioFramePosition(frames)
                    packets.append(packet)
                }
            case .endOfStream:
                return packets
            case .inputRanDry:
                return packets
            case .error:
                throw LiveStreamError.encoderFailed("AVAudioConverter returned error status")
            @unknown default:
                return packets
            }
        }

        return packets
    }

    private func extractPacketData(from buffer: AVAudioCompressedBuffer) -> Data? {
        let size = Int(buffer.byteLength)
        guard size > 0, let ptr = buffer.data.bindMemory(to: UInt8.self, capacity: size) as UnsafeMutablePointer<UInt8>? else {
            return nil
        }
        return Data(bytes: ptr, count: size)
    }
}

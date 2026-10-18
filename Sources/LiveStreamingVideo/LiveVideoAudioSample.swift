@preconcurrency import AVFoundation

/// Bridges an already mixed PCM buffer into the host-clock timeline. The audio
/// tap's AVAudioTime must carry hostTime; a cumulative frame cursor is insufficient.
public enum LiveVideoAudioSample {
    public static func make(buffer: AVAudioPCMBuffer, at time: AVAudioTime) throws -> CMSampleBuffer {
        guard time.isHostTimeValid, buffer.frameLength > 0,
              [44_100.0, 48_000.0].contains(buffer.format.sampleRate) else {
            throw LiveVideoError.invalidSample("Audio requires nonempty PCM and a valid host timestamp")
        }
        var description: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: buffer.format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description
        )
        guard formatStatus == noErr, let description else {
            throw LiveVideoError.invalidSample("Cannot describe PCM format (\(formatStatus))")
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: CMClockMakeHostTimeFromSystemUnits(time.hostTime),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
            sampleCount: Int(buffer.frameLength), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample
        )
        guard sampleStatus == noErr, let sample else {
            throw LiveVideoError.invalidSample("Cannot create audio sample (\(sampleStatus))")
        }
        // Core Media copies the data; the audio engine can safely reuse its tap buffer.
        let dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
            bufferList: buffer.audioBufferList
        )
        guard dataStatus == noErr else {
            throw LiveVideoError.invalidSample("Cannot copy PCM data (\(dataStatus))")
        }
        let readyStatus = CMSampleBufferSetDataReady(sample)
        guard readyStatus == noErr else {
            throw LiveVideoError.invalidSample("Cannot mark PCM ready (\(readyStatus))")
        }
        return sample
    }
}

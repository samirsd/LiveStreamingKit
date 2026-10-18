import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import UniformTypeIdentifiers

/// Encodes raw camera frames and PCM audio into one H.264/AAC fragmented MP4 stream.
///
/// `hostTime` must identify the first sample in the buffer on the same monotonic clock
/// as `epoch`. Camera and audio sources must convert their timestamps to that clock;
/// the time a callback happens to arrive is not a synchronization timestamp.
///
/// Append calls only admit work to a bounded queue. A `true` result means admitted,
/// not necessarily encoded: encoder backpressure is reported through `onDrop`.
/// Callbacks run on the writer's serial processing queue and should return promptly.
public final class FragmentedMP4Writer: NSObject, @unchecked Sendable {
    private struct Sample: @unchecked Sendable {
        let buffer: CMSampleBuffer
        let hostTime: CMTime
        let mediaType: LiveVideoMediaType
    }

    private enum State {
        case writing, finishing, completed
        case failed(LiveVideoError)
    }

    private let configuration: LiveVideoConfiguration
    private let epoch: CMTime
    private let onSegment: @Sendable (LiveVideoSegment) -> Void
    private let onFailure: @Sendable (LiveVideoError) -> Void
    private let onDrop: @Sendable (LiveVideoMediaType) -> Void
    private let queue = DispatchQueue(label: "LiveStreamingVideo.FragmentedMP4Writer")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let admissionLock = NSLock()
    // These values are accessed only while holding admissionLock.
    private var accepting = true
    private var pendingSamples = 0
    private var pendingAudioDrops = 0
    private var pendingVideoDrops = 0
    private var dropDeliveryScheduled = false

    // All remaining mutable state belongs to queue.
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private var state: State = .writing
    private var videoFormat: CMFormatDescription?
    private var audioFormat: CMFormatDescription?
    private var lastVideoTime: CMTime?
    private var lastAudioTime: CMTime?
    private var lastAudioEndTime: CMTime?
    private var mediaSequence = 0
    private var sawInitialization = false
    private var appendedVideo = false
    private var appendedAudio = false
    private var finishWaiters: [CheckedContinuation<Void, Error>] = []

    // Leave enough positive media time for the AAC encoder's leading priming frames.
    // HLS players use each fragment's timestamps rather than treating this as silence.
    private static let mediaOrigin = CMTime(seconds: 10, preferredTimescale: 48_000)

    public init(
        configuration: LiveVideoConfiguration,
        epoch: CMTime,
        onSegment: @escaping @Sendable (LiveVideoSegment) -> Void,
        onFailure: @escaping @Sendable (LiveVideoError) -> Void,
        onDrop: @escaping @Sendable (LiveVideoMediaType) -> Void
    ) throws {
        try configuration.validate()
        guard epoch.isNumeric, epoch.seconds.isFinite else {
            throw LiveVideoError.invalidConfiguration("The shared capture epoch must be a numeric host-clock time.")
        }
        self.configuration = configuration
        self.epoch = epoch
        self.onSegment = onSegment
        self.onFailure = onFailure
        self.onDrop = onDrop

        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        self.writer = writer
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: configuration.segmentDuration, preferredTimescale: 60_000)
        writer.initialSegmentStartTime = Self.mediaOrigin

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.videoWidth,
            AVVideoHeightKey: configuration.videoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: configuration.videoBitrate,
                AVVideoExpectedSourceFrameRateKey: configuration.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: max(1, Int((Double(configuration.framesPerSecond) * configuration.segmentDuration).rounded())),
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: configuration.audioSampleRate,
            AVNumberOfChannelsKey: configuration.audioChannelCount,
            AVEncoderBitRateKey: configuration.audioBitrate
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video),
              writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
            throw LiveVideoError.encodingFailed("This device cannot encode the requested H.264/AAC configuration.")
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        videoInput.mediaTimeScale = 60_000
        videoInput.expectsMediaDataInRealTime = true
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw LiveVideoError.encodingFailed("The fragmented MP4 writer cannot accept both camera and audio inputs.")
        }
        writer.add(videoInput)
        writer.add(audioInput)
        super.init()
        queue.setSpecific(key: queueKey, value: true)
        writer.delegate = self
        guard writer.startWriting() else {
            throw LiveVideoError.encodingFailed(writer.error?.localizedDescription ?? "Unable to start the video encoder.")
        }
        writer.startSession(atSourceTime: .zero)
    }

    @discardableResult
    public func appendVideo(_ sampleBuffer: CMSampleBuffer, at hostTime: CMTime) -> Bool {
        admit(Sample(buffer: sampleBuffer, hostTime: hostTime, mediaType: .video))
    }

    @discardableResult
    public func appendAudio(_ sampleBuffer: CMSampleBuffer, at hostTime: CMTime) -> Bool {
        admit(Sample(buffer: sampleBuffer, hostTime: hostTime, mediaType: .audio))
    }

    /// Drains previously admitted samples and emits the final complete fragment.
    /// Calling this more than once waits on the same terminal result.
    /// Cancelling the awaiting task does not discard admitted recording data;
    /// call `cancel()` explicitly when the encoding itself should be abandoned.
    public func finish() async throws {
        try await withCheckedThrowingContinuation { continuation in
            admissionLock.lock()
            accepting = false
            queue.async { [self] in finishOnQueue(continuation) }
            admissionLock.unlock()
        }
    }

    /// Cancels outstanding encoding. No segment callback is issued after cancellation
    /// has been processed on the serial queue. A cancelled writer cannot be reused.
    public func cancel() {
        admissionLock.lock()
        accepting = false
        queue.async { [self] in
            switch state {
            case .completed, .failed: return
            case .writing, .finishing:
                fail(.invalidState("Video encoding was cancelled."), report: false)
            }
        }
        admissionLock.unlock()
    }

    private func admit(_ sample: Sample) -> Bool {
        admissionLock.lock()
        guard accepting else {
            admissionLock.unlock()
            return false
        }
        guard pendingSamples < configuration.maxPendingSamples else {
            // Aggregate rejected admissions rather than allocating an unbounded queue
            // of callback closures when a capture source outruns the encoder.
            if sample.mediaType == .audio { pendingAudioDrops += 1 }
            else { pendingVideoDrops += 1 }
            if !dropDeliveryScheduled {
                dropDeliveryScheduled = true
                queue.async { [self] in deliverAdmissionDrops() }
            }
            admissionLock.unlock()
            return false
        }
        pendingSamples += 1
        // Enqueue under the lock so finish/cancel cannot overtake an admitted buffer.
        queue.async { [self] in
            defer {
                admissionLock.lock()
                pendingSamples -= 1
                admissionLock.unlock()
            }
            process(sample)
        }
        admissionLock.unlock()
        return true
    }

    private func deliverAdmissionDrops() {
        admissionLock.lock()
        let audioCount = pendingAudioDrops
        let videoCount = pendingVideoDrops
        pendingAudioDrops = 0
        pendingVideoDrops = 0
        dropDeliveryScheduled = false
        admissionLock.unlock()
        guard case .writing = state else { return }
        for _ in 0..<audioCount { onDrop(.audio) }
        for _ in 0..<videoCount { onDrop(.video) }
    }

    private func process(_ sample: Sample) {
        guard case .writing = state else { return }
        do {
            if sample.hostTime.isNumeric, sample.hostTime.seconds.isFinite,
               CMTimeCompare(sample.hostTime, epoch) < 0 {
                let hasAcceptedSample = sample.mediaType == .video ? lastVideoTime != nil : lastAudioTime != nil
                guard !hasAcceptedSample else {
                    throw LiveVideoError.invalidSample("Capture timestamps moved backwards before the shared epoch.")
                }
                // Capture outputs can deliver a previously queued buffer immediately
                // after a session starts. Do not let that startup pre-roll fail an
                // otherwise valid session or move the shared epoch independently.
                onDrop(sample.mediaType)
                return
            }
            let retimed = try validateAndRetime(sample)
            let input = sample.mediaType == .video ? videoInput : audioInput
            guard writer.status == .writing else {
                throw LiveVideoError.encodingFailed(writer.error?.localizedDescription ?? "The video encoder stopped unexpectedly.")
            }
            guard input.isReadyForMoreMediaData else {
                onDrop(sample.mediaType)
                return
            }
            guard input.append(retimed) else {
                throw LiveVideoError.encodingFailed(writer.error?.localizedDescription ?? "The encoder rejected a media sample.")
            }
            if sample.mediaType == .video { appendedVideo = true }
            else { appendedAudio = true }
        } catch let error as LiveVideoError {
            fail(error)
        } catch {
            fail(.encodingFailed(error.localizedDescription))
        }
    }

    private func validateAndRetime(_ sample: Sample) throws -> CMSampleBuffer {
        guard CMSampleBufferIsValid(sample.buffer), CMSampleBufferDataIsReady(sample.buffer),
              CMSampleBufferGetNumSamples(sample.buffer) > 0,
              let format = CMSampleBufferGetFormatDescription(sample.buffer) else {
            throw LiveVideoError.invalidSample("A capture buffer has no ready media data or format description.")
        }
        guard sample.hostTime.isNumeric, sample.hostTime.seconds.isFinite,
              CMTimeCompare(sample.hostTime, epoch) >= 0 else {
            throw LiveVideoError.invalidSample("Capture timestamps must be numeric host-clock times at or after the shared epoch.")
        }
        let originalPTS = CMSampleBufferGetPresentationTimeStamp(sample.buffer)
        guard originalPTS.isNumeric, originalPTS.seconds.isFinite else {
            throw LiveVideoError.invalidSample("A capture buffer has no numeric presentation timestamp.")
        }
        switch sample.mediaType {
        case .video:
            guard CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video,
                  CMSampleBufferGetNumSamples(sample.buffer) == 1,
                  let pixels = CMSampleBufferGetImageBuffer(sample.buffer),
                  CVPixelBufferGetWidth(pixels) == configuration.videoWidth,
                  CVPixelBufferGetHeight(pixels) == configuration.videoHeight else {
                throw LiveVideoError.invalidSample("Camera buffers must contain one raw frame matching the configured dimensions.")
            }
            if let videoFormat, !CMFormatDescriptionEqual(videoFormat, otherFormatDescription: format) {
                throw LiveVideoError.invalidSample("The camera format changed during the live session. Start a new session for the new format.")
            }
            if let lastVideoTime, CMTimeCompare(sample.hostTime, lastVideoTime) <= 0 {
                throw LiveVideoError.invalidSample("Camera timestamps must increase monotonically.")
            }
            videoFormat = format
            lastVideoTime = sample.hostTime
        case .audio:
            guard CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  asbd.mFormatID == kAudioFormatLinearPCM,
                  abs(asbd.mSampleRate - configuration.audioSampleRate) < 0.01,
                  Int(asbd.mChannelsPerFrame) == configuration.audioChannelCount,
                  CMSampleBufferGetNumSamples(sample.buffer) <= Int(configuration.audioSampleRate) else {
                throw LiveVideoError.invalidSample("Audio buffers must contain at most one second of PCM at the configured rate and channel count.")
            }
            if let audioFormat, !CMFormatDescriptionEqual(audioFormat, otherFormatDescription: format) {
                throw LiveVideoError.invalidSample("The PCM audio format changed during the live session. Start a new session for the new format.")
            }
            if let lastAudioTime, CMTimeCompare(sample.hostTime, lastAudioTime) <= 0 {
                throw LiveVideoError.invalidSample("Audio timestamps must increase monotonically.")
            }
            // Permit one sample of clock-conversion rounding, but reject overlapping
            // PCM blocks instead of silently encoding duplicate audio on the timeline.
            if let lastAudioEndTime,
               CMTimeCompare(sample.hostTime, CMTimeSubtract(lastAudioEndTime, CMTime(value: 1, timescale: Int32(configuration.audioSampleRate)))) < 0 {
                throw LiveVideoError.invalidSample("PCM buffers overlap on the shared capture timeline.")
            }
            audioFormat = format
            lastAudioTime = sample.hostTime
            lastAudioEndTime = CMTimeAdd(sample.hostTime, CMTime(value: Int64(CMSampleBufferGetNumSamples(sample.buffer)), timescale: Int32(configuration.audioSampleRate)))
        }
        var mappedTime = CMTimeAdd(Self.mediaOrigin, CMTimeSubtract(sample.hostTime, epoch))
        if sample.mediaType == .audio {
            mappedTime = CMTimeAdd(mappedTime, CMTime(seconds: configuration.audioOffset, preferredTimescale: 60_000))
        }
        guard mappedTime.isNumeric, mappedTime.seconds.isFinite, CMTimeCompare(mappedTime, .zero) >= 0 else {
            throw LiveVideoError.invalidSample("The audio synchronization offset produces a negative media timestamp.")
        }
        let shift = CMTimeSubtract(mappedTime, originalPTS)
        var timingCount = 0
        var result = CMSampleBufferGetSampleTimingInfoArray(sample.buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingCount)
        guard result == noErr, timingCount > 0, timingCount <= CMSampleBufferGetNumSamples(sample.buffer) else {
            throw LiveVideoError.invalidSample("Unable to read capture sample timing (\(result)).")
        }
        var timing = Array(repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: timingCount)
        result = CMSampleBufferGetSampleTimingInfoArray(sample.buffer, entryCount: timingCount, arrayToFill: &timing, entriesNeededOut: nil)
        guard result == noErr else {
            throw LiveVideoError.invalidSample("Unable to read capture sample timing (\(result)).")
        }
        for index in timing.indices {
            guard timing[index].presentationTimeStamp.isNumeric else {
                throw LiveVideoError.invalidSample("A sample within the capture buffer has invalid timing.")
            }
            timing[index].presentationTimeStamp = CMTimeAdd(timing[index].presentationTimeStamp, shift)
            if timing[index].decodeTimeStamp.isNumeric {
                timing[index].decodeTimeStamp = CMTimeAdd(timing[index].decodeTimeStamp, shift)
            }
        }
        var copy: CMSampleBuffer?
        result = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample.buffer, sampleTimingEntryCount: timingCount, sampleTimingArray: &timing, sampleBufferOut: &copy)
        guard result == noErr, let copy else {
            throw LiveVideoError.invalidSample("Unable to align capture timestamps (\(result)).")
        }
        return copy
    }

    private func finishOnQueue(_ continuation: CheckedContinuation<Void, Error>) {
        switch state {
        case .completed:
            continuation.resume()
        case .failed(let error):
            continuation.resume(throwing: error)
        case .finishing:
            finishWaiters.append(continuation)
        case .writing:
            finishWaiters.append(continuation)
            guard appendedVideo, appendedAudio else {
                fail(.invalidState("A video stream needs both camera frames and PCM audio before it can finish."))
                return
            }
            state = .finishing
            videoInput.markAsFinished()
            audioInput.markAsFinished()
            writer.finishWriting { [self] in
                queue.async { [self] in
                    guard case .finishing = state else { return }
                    guard writer.status == .completed else {
                        fail(.encodingFailed(writer.error?.localizedDescription ?? "Unable to finalize the live video stream."))
                        return
                    }
                    guard sawInitialization, mediaSequence > 0 else {
                        fail(.encodingFailed("The encoder finished without a complete MP4 initialization and media fragment."))
                        return
                    }
                    state = .completed
                    let waiters = finishWaiters
                    finishWaiters.removeAll()
                    waiters.forEach { $0.resume() }
                }
            }
        }
    }

    private func fail(_ error: LiveVideoError, report: Bool = true) {
        switch state {
        case .completed, .failed: return
        case .writing, .finishing: break
        }
        state = .failed(error)
        admissionLock.lock()
        accepting = false
        admissionLock.unlock()
        // cancelWriting blocks until AVFoundation has cancelled. Its delegate may
        // already be waiting to deliver a segment on queue, so cancellation must not
        // block that queue. The extra serial turn ensures append has unwound first.
        queue.async { [self] in
            DispatchQueue.global(qos: .utility).async { [self] in writer.cancelWriting() }
        }
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
        if report { onFailure(error) }
    }

    private func receive(_ data: Data, type: AVAssetSegmentType, report: AVAssetSegmentReport?) {
        switch state {
        case .writing, .finishing: break
        case .completed, .failed: return
        }
        guard !data.isEmpty else {
            fail(.encodingFailed("The encoder emitted an empty MP4 fragment."))
            return
        }
        switch type {
        case .initialization:
            guard !sawInitialization else {
                fail(.encodingFailed("The encoder emitted more than one MP4 initialization fragment."))
                return
            }
            sawInitialization = true
            onSegment(LiveVideoSegment(kind: .initialization, sequence: 0, data: data, duration: 0))
        case .separable:
            guard sawInitialization else {
                fail(.encodingFailed("The encoder emitted media before MP4 initialization."))
                return
            }
            let durations = report?.trackReports.compactMap { track -> TimeInterval? in
                let value = track.duration.seconds
                return track.duration.isNumeric && value.isFinite && value > 0 ? value : nil
            } ?? []
            guard let duration = durations.max() else {
                fail(.encodingFailed("The encoder emitted a fragment without a valid media duration."))
                return
            }
            let sequence = mediaSequence
            mediaSequence += 1
            let timings = report?.trackReports.compactMap { track -> LiveVideoTrackTiming? in
                let time = track.earliestPresentationTimeStamp
                guard time.isNumeric, time.seconds.isFinite else { return nil }
                let mediaType: LiveVideoMediaType
                switch track.mediaType {
                case .video: mediaType = .video
                case .audio: mediaType = .audio
                default: return nil
                }
                return LiveVideoTrackTiming(trackID: track.trackID, mediaType: mediaType,
                                            presentationTimeValue: time.value, presentationTimescale: time.timescale)
            } ?? []
            onSegment(LiveVideoSegment(kind: .media, sequence: sequence, data: data, duration: duration, trackTimings: timings))
        @unknown default:
            fail(.encodingFailed("The encoder emitted an unsupported fragment type."))
        }
    }
}

extension FragmentedMP4Writer: AVAssetWriterDelegate {
    public func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        guard writer === self.writer else { return }
        // Copy the delegate-owned storage before returning to AVFoundation.
        let data = segmentData.withUnsafeBytes { Data($0) }
        if DispatchQueue.getSpecific(key: queueKey) == true {
            receive(data, type: segmentType, report: segmentReport)
        } else {
            queue.sync { [self] in receive(data, type: segmentType, report: segmentReport) }
        }
    }
}

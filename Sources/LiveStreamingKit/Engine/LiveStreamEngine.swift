import Foundation
@preconcurrency import AVFoundation
import AIMixKit
import os

public final class LiveStreamEngine: AudioBufferObserver, @unchecked Sendable {
    public typealias EventHandler = @Sendable (LiveStreamEvent) -> Void

    private struct PipelineState: @unchecked Sendable {
        var liveState: LiveStreamState = .idle
        var session: LiveStreamSession?
        var uploader: LiveStreamUploader?
        var sourceFormat: AVAudioFormat?
        var downmixer: StereoDownmixer?
        var aiMixProcessor: AIMixProcessor?
        var encoder: AACEncoder?
        var segmenter: HLSSegmenter?

        func aiMixProcessorIsReady(for mode: LiveStreamAIMixMode) -> Bool {
            switch mode {
            case .off:
                return aiMixProcessor == nil
            case .broadcastPolish:
                return aiMixProcessor != nil
            }
        }
    }

    private let config: LiveStreamConfig
    private let client: LiveStreamClient
    private let onEvent: EventHandler
    private let state = OSAllocatedUnfairLock(initialState: PipelineState())
    private let processingQueue = DispatchQueue(label: "carnyx.livestream.engine", qos: .userInitiated)

    public var liveState: LiveStreamState {
        state.withLock { $0.liveState }
    }

    public var currentSession: LiveStreamSession? {
        state.withLock { $0.session }
    }

    public init(
        config: LiveStreamConfig,
        transport: HTTPTransport = URLSessionHTTPTransport(),
        onEvent: @escaping EventHandler
    ) {
        self.config = config
        self.client = LiveStreamClient(config: config, transport: transport)
        self.onEvent = onEvent
    }

    public func start() async throws -> LiveStreamSession {
        try transition { current in
            switch current {
            case .idle, .stopped, .failed:
                return .preparing
            case .preparing, .live, .stopping:
                throw LiveStreamError.sessionAlreadyStarted
            }
        }
        do {
            let newSession = try await client.createSession()
            let uploader = LiveStreamUploader(
                client: client,
                session: newSession,
                maxRetries: config.maxSegmentRetries,
                maxBuffered: config.maxBufferedSegments,
                onEvent: onEvent
            )
            state.withLock { pipeline in
                pipeline.session = newSession
                pipeline.uploader = uploader
            }
            try transition { _ in .live(session: newSession, since: Date()) }
            return newSession
        } catch {
            let mapped = mapStartError(error)
            try? transition { _ in .failed(mapped) }
            throw mapped
        }
    }

    public func stop(reason: LiveStreamState.StopReason = .requested) async {
        // No-op from terminal/initial states — only `.live` / `.preparing` can be stopped.
        let shouldProceed = state.withLock { pipeline -> Bool in
            switch pipeline.liveState {
            case .live, .preparing: return true
            default: return false
            }
        }
        guard shouldProceed else { return }

        let snapshot: (LiveStreamUploader?, LiveStreamSession?, HLSSegmenter?) = state.withLock { pipeline in
            (pipeline.uploader, pipeline.session, pipeline.segmenter)
        }
        try? transition { current in
            switch current {
            case .live, .preparing:
                return .stopping
            default:
                return current
            }
        }
        if let segmenter = snapshot.2, let finalSegment = segmenter.finish() {
            await snapshot.0?.enqueue(finalSegment)
        }
        await snapshot.0?.drainAndStop()
        if let activeSession = snapshot.1 {
            try? await client.endSession(activeSession)
        }
        try? transition { _ in .stopped(reason: reason) }
    }

    // MARK: - AudioBufferObserver

    public func observe(buffer: AVAudioPCMBuffer, at sampleTime: AVAudioFramePosition) {
        let copy = Self.copyBuffer(buffer)
        processingQueue.async { [weak self] in
            self?.handleBuffer(copy, sampleTime: sampleTime)
        }
    }

    private func handleBuffer(_ buffer: AVAudioPCMBuffer?, sampleTime: AVAudioFramePosition) {
        guard let buffer else { return }
        let currentState = liveState
        switch currentState {
        case .live, .preparing:
            break
        default:
            return
        }

        ensurePipelineReady(for: buffer)

        let pipeline: (StereoDownmixer?, AIMixProcessor?, AACEncoder?, HLSSegmenter?, LiveStreamUploader?) = state.withLock { pipeline in
            (pipeline.downmixer, pipeline.aiMixProcessor, pipeline.encoder, pipeline.segmenter, pipeline.uploader)
        }
        guard let downmixer = pipeline.0,
              let encoder = pipeline.2,
              let segmenter = pipeline.3,
              let uploader = pipeline.4 else { return }
        guard let stereo = downmixer.downmix(buffer) else { return }
        let streamBuffer: AVAudioPCMBuffer
        if let aiMixProcessor = pipeline.1,
           let processed = aiMixProcessor.process(stereo, at: sampleTime) {
            streamBuffer = processed.buffer
            onEvent(.aiMixMeasured(
                inputRMSDB: processed.snapshot.inputRMSDB,
                outputPeakDB: processed.snapshot.outputPeakDB,
                appliedGainDB: processed.snapshot.appliedGainDB,
                limiterGainReductionDB: processed.snapshot.limiterGainReductionDB
            ))
        } else {
            streamBuffer = stereo
        }
        do {
            let packets = try encoder.encode(streamBuffer)
            for packet in packets {
                if let segment = segmenter.append(packet) {
                    onEvent(.segmentEncoded(
                        sequence: segment.sequence,
                        bytes: segment.data.count,
                        duration: segment.duration
                    ))
                    Task { await uploader.enqueue(segment) }
                }
            }
        } catch {
            onEvent(.stateChanged(.failed(.encoderFailed(String(describing: error)))))
        }
    }

    private func ensurePipelineReady(for buffer: AVAudioPCMBuffer) {
        let inputSampleRate = buffer.format.sampleRate
        let inputChannelCount = buffer.format.channelCount
        let needsRebuild = state.withLock { pipeline -> Bool in
            if let existing = pipeline.sourceFormat,
               existing.sampleRate == inputSampleRate,
               existing.channelCount == inputChannelCount,
               pipeline.downmixer != nil,
               pipeline.aiMixProcessorIsReady(for: config.aiMixMode),
               pipeline.encoder != nil,
               pipeline.segmenter != nil {
                return false
            }
            return true
        }
        guard needsRebuild else { return }
        guard let downmixer = StereoDownmixer(
            sampleRate: inputSampleRate,
            channelMap: config.channelMap
        ) else { return }
        guard let encoder = AACEncoder(
            sourceFormat: downmixer.outputFormat,
            sampleRate: config.sampleRate,
            bitrate: config.stereoBitrate
        ) else { return }
        let aiMixProcessor = Self.makeAIMixProcessor(mode: config.aiMixMode)
        let segmenter = HLSSegmenter(
            targetDuration: config.segmentDuration,
            sampleRate: config.sampleRate,
            channelCount: 2
        )
        let sourceFormat = buffer.format
        state.withLock { pipeline in
            pipeline.sourceFormat = sourceFormat
            pipeline.downmixer = downmixer
            pipeline.aiMixProcessor = aiMixProcessor
            pipeline.encoder = encoder
            pipeline.segmenter = segmenter
        }
    }

    private static func makeAIMixProcessor(mode: LiveStreamAIMixMode) -> AIMixProcessor? {
        switch mode {
        case .off:
            return nil
        case .broadcastPolish:
            return AIMixProcessor(configuration: .broadcastPolish)
        }
    }

    private static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameCapacity) else {
            return nil
        }
        copy.frameLength = source.frameLength
        guard let src = source.floatChannelData, let dst = copy.floatChannelData else { return nil }
        let channels = Int(source.format.channelCount)
        let bytes = Int(source.frameLength) * MemoryLayout<Float>.size
        for channel in 0..<channels {
            memcpy(dst[channel], src[channel], bytes)
        }
        return copy
    }

    private func transition(_ mutate: @Sendable (LiveStreamState) throws -> LiveStreamState) throws {
        let outcome: Result<(LiveStreamState, LiveStreamState), TransitionError> = state.withLock { pipeline in
            do {
                let old = pipeline.liveState
                let next = try mutate(old)
                pipeline.liveState = next
                return .success((old, next))
            } catch let liveError as LiveStreamError {
                return .failure(.live(liveError))
            } catch {
                return .failure(.other(String(describing: error)))
            }
        }
        switch outcome {
        case .success(let (old, next)):
            if next != old { onEvent(.stateChanged(next)) }
        case .failure(let error):
            throw error.unwrap()
        }
    }

    private enum TransitionError: Error, Sendable {
        case live(LiveStreamError)
        case other(String)
        func unwrap() -> Error {
            switch self {
            case .live(let live): return live
            case .other(let message):
                return LiveStreamError.invalidConfiguration(message)
            }
        }
    }

    private func mapStartError(_ error: Error) -> LiveStreamError {
        if let live = error as? LiveStreamError { return live }
        return .backendUnreachable(config.ingestBaseURL)
    }
}

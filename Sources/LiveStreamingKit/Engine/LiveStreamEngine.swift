import Foundation
@preconcurrency import AVFoundation
import AIMixKit
import LoggingKit
import os

public final class LiveStreamEngine: AudioBufferObserver, @unchecked Sendable {
    public typealias EventHandler = @Sendable (LiveStreamEvent) -> Void

    private struct PipelineState: @unchecked Sendable {
        var liveState: LiveStreamState = .idle
        var generation: UUID?
        var socialPoller: LiveStreamSocialPoller?
        var deliveryTask: Task<Void, Never>?
        var session: LiveStreamSession?
        var uploader: LiveStreamUploader?
        var archive: LiveStreamArchive?
        var sourceFormat: AVAudioFormat?
        var downmixer: StereoDownmixer?
        var aiMixProcessor: AIMixProcessor?
        var encoder: AACEncoder?
        var segmenter: HLSSegmenter?
        var hasReceivedFirstBuffer: Bool = false
        var segmentsEncoded: Int = 0
        // True while an external audio interruption (phone call, Siri,
        // route change, etc.) is paused upstream. `handleBuffer` drops
        // incoming buffers while this is set so the listener gets a
        // clean silence instead of garbled samples.
        var isInterrupted: Bool = false
        var interruptionStartedAt: Date?
        // Health-check inputs. The engine's monitor task reads these on a
        // fixed interval and decides whether to emit a health-change event.
        var lastEncodeAt: Date?
        var lastUploadAt: Date?
        var lastHealth: LiveStreamHealth = .healthy

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
    private let externalEventHandler: EventHandler
    // Serialize state changes and their synchronous event emissions. Never held across await.
    private let lifecycleLock = NSRecursiveLock()
    private let state = OSAllocatedUnfairLock(initialState: PipelineState())
    private let processingQueue = DispatchQueue(label: "carnyx.livestream.engine", qos: .userInitiated)
    private var healthMonitorTask: Task<Void, Never>?

    /// All event emissions funnel through here so the engine can update
    /// internal health bookkeeping (last-encode-at, last-upload-at) before
    /// forwarding to the host. Putting this in one place keeps the health
    /// logic from sprawling through every event-emitting site.
    private func onEvent(_ event: LiveStreamEvent) {
        switch event {
        case .segmentEncoded:
            state.withLock { $0.lastEncodeAt = Date() }
        case .segmentUploaded:
            state.withLock { $0.lastUploadAt = Date() }
        default:
            break
        }
        externalEventHandler(event)
    }

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
        let client = LiveStreamClient(config: config, transport: transport)
        self.client = client
        self.externalEventHandler = onEvent
    }

    public func start() async throws -> LiveStreamSession {
        LiveStreamLog.engine.info(
            "start requested host=\(self.config.ingestBaseURL.host ?? "?", privacy: .public) sampleRate=\(self.config.sampleRate, privacy: .public) bitrate=\(self.config.stereoBitrate, privacy: .public) segmentDuration=\(self.config.segmentDuration, privacy: .public) aiMix=\(String(describing: self.config.aiMixMode), privacy: .public)"
        )
        VisibilityDiagnostics.trackFeatureAction(
            surface: .liveStreaming,
            feature: "broadcast",
            action: "start",
            phase: .started,
            properties: [
                "sample_rate": "\(Int(config.sampleRate))",
                "duration_seconds": "\(config.segmentDuration)"
            ]
        )
        let generation = UUID()
        try withLifecycleLock {
            try transition { current in
                switch current {
                case .idle, .stopped, .failed:
                    return .preparing
                case .preparing, .live, .stopping:
                    throw LiveStreamError.sessionAlreadyStarted
                }
            }
            state.withLock { pipeline in
                pipeline = PipelineState(liveState: .preparing, generation: generation)
            }
        }
        do {
            let newSession = try await client.createSession()
            LiveStreamLog.engine.info(
                "session created id=\(newSession.id, privacy: .public) ingest=\(newSession.ingestURL.absoluteString, privacy: .public)"
            )
            guard !Task.isCancelled, isPreparing(generation) else {
                await endOrphanSession(newSession)
                throw CancellationError()
            }
            let uploader = LiveStreamUploader(
                client: client,
                session: newSession,
                maxRetries: config.maxSegmentRetries,
                maxBuffered: config.maxBufferedSegments,
                onEvent: { [weak self] event in self?.onEvent(event, generation: generation) },
                deliveryBudgetSeconds: config.segmentDeliveryBudgetSeconds,
                maxBackoffSeconds: config.maxRetryBackoffSeconds
            )
            // Open the local archive file if the host opted in. Failures
            // here are non-fatal — the broadcast goes live without an
            // archive, the user just doesn't get a local copy.
            let archive: LiveStreamArchive? = {
                guard let url = config.archivePolicy.resolveURL(sessionID: newSession.id) else {
                    return nil
                }
                let opened = LiveStreamArchive(fileURL: url)
                if opened != nil {
                    LiveStreamLog.engine.info(
                        "archive opened path=\(url.path, privacy: .public)"
                    )
                }
                return opened
            }()
            let poller = LiveStreamSocialPoller(client: client) { [weak self] event in
                self?.onEvent(event, generation: generation)
            }
            await poller.start(newSession)
            let accepted = withLifecycleLock { () -> Bool in
                guard !Task.isCancelled, isPreparing(generation) else { return false }
                state.withLock { pipeline in
                    pipeline.session = newSession
                    pipeline.uploader = uploader
                    pipeline.archive = archive
                    pipeline.socialPoller = poller
                }
                try? transition { _ in .live(session: newSession, since: Date()) }
                startHealthMonitor()
                return true
            }
            guard accepted else {
                await poller.stop()
                await uploader.drainAndStop()
                if let archive { await archive.finalize() }
                await endOrphanSession(newSession)
                throw CancellationError()
            }
            VisibilityDiagnostics.trackFeatureAction(
                surface: .liveStreaming,
                feature: "broadcast",
                action: "start",
                phase: .completed,
                properties: [
                    "sample_rate": "\(Int(config.sampleRate))",
                    "duration_seconds": "\(config.segmentDuration)"
                ]
            )
            return newSession
        } catch {
            if error is CancellationError || Task.isCancelled || !isPreparing(generation) {
                withLifecycleLock {
                    guard isPreparing(generation) else { return }
                    state.withLock { $0.generation = nil }
                    try? transition { _ in .stopped(reason: .requested) }
                }
                throw CancellationError()
            }
            let mapped = mapStartError(error)
            LiveStreamLog.engine.error(
                "start failed category=\(mapped.telemetryCategory, privacy: .public) reason=\(String(describing: mapped), privacy: .public) raw=\(String(describing: error), privacy: .public)"
            )
            VisibilityDiagnostics.trackFeatureAction(
                surface: .liveStreaming,
                feature: "broadcast",
                action: "start",
                phase: .failed,
                properties: [
                    "error_message": mapped.telemetryCategory,
                    "error_domain": "LiveStreamError"
                ]
            )
            VisibilityDiagnostics.captureError(
                mapped,
                context: "livestream_start",
                properties: ["error_category": mapped.telemetryCategory]
            )
            withLifecycleLock {
                guard isPreparing(generation) else { return }
                state.withLock { $0.generation = nil }
                try? transition { _ in .failed(mapped) }
            }
            throw mapped
        }
    }

    public func stop(reason: LiveStreamState.StopReason = .requested) async {
        guard claimStop() else { return }
        await finishStop(reason: reason)
    }

    private func claimStop() -> Bool {
        // Claim the stop before the first suspension. A pending create may
        // still return, but its generation can no longer publish a live session.
        withLifecycleLock {
            let canStop = state.withLock { pipeline -> Bool in
                switch pipeline.liveState {
                case .live, .preparing:
                    pipeline.generation = nil
                    return true
                default: return false
                }
            }
            guard canStop else { return false }
            try? transition { _ in .stopping }
            stopHealthMonitor()
            return true
        }
    }

    private func finishStop(reason: LiveStreamState.StopReason, failure: LiveStreamError? = nil) async {
        LiveStreamLog.engine.info("stop requested reason=\(String(describing: reason), privacy: .public)")
        VisibilityDiagnostics.trackFeatureAction(
            surface: .liveStreaming,
            feature: "broadcast",
            action: "stop",
            phase: .started,
            properties: ["source": "\(reason)"]
        )

        let poller = state.withLock { $0.socialPoller }
        await poller?.stop()

        // Finish only after any buffer already encoding on the serial queue.
        // The stopping state prevents queued/new buffers from entering the pipeline.
        await flushProcessingQueue()
        let snapshot = state.withLock { pipeline in
            (pipeline.uploader, pipeline.session, pipeline.segmenter,
             pipeline.segmentsEncoded, pipeline.archive, pipeline.deliveryTask)
        }
        await snapshot.5?.value
        var deliveredSegmentCount = snapshot.3
        if let segmenter = snapshot.2, let finalSegment = segmenter.finish() {
            deliveredSegmentCount = state.withLock { pipeline in
                pipeline.segmentsEncoded += 1
                return pipeline.segmentsEncoded
            }
            LiveStreamLog.engine.debug("enqueueing final segment seq=\(finalSegment.sequence, privacy: .public)")
            // Mirror to the archive so it captures the tail of the stream
            // before the file handle closes.
            if let archive = snapshot.4 {
                await archive.append(finalSegment.data)
            }
            if reason != .backendClosed { await snapshot.0?.enqueue(finalSegment) }
        }
        if reason == .backendClosed {
            await snapshot.0?.cancelAndStop()
        } else {
            await snapshot.0?.drainAndStop()
        }
        if let activeSession = snapshot.1 {
            do {
                try await client.endSession(activeSession)
                LiveStreamLog.engine.info("session ended cleanly id=\(activeSession.id, privacy: .public) segments=\(deliveredSegmentCount, privacy: .public)")
            } catch {
                // We're shutting down — log but don't fail the stop path.
                LiveStreamLog.engine.error("endSession failed id=\(activeSession.id, privacy: .public) error=\(String(describing: error), privacy: .public)")
                VisibilityDiagnostics.recordBreadcrumb(
                    category: "LiveStreaming",
                    message: "end_session_failed",
                    level: .warning,
                    properties: ["error_message": String(describing: error)]
                )
            }
        }
        // Finalize the local archive last, after the uploader has drained
        // any tail segments. The archiveSaved event is the consumer's cue
        // to surface "share broadcast" UI.
        if let archive = snapshot.4 {
            let (url, bytes) = await archive.finalize()
            if bytes > 0 {
                onEvent(.archiveSaved(url: url, byteCount: bytes))
                VisibilityDiagnostics.trackFeatureAction(
                    surface: .liveStreaming,
                    feature: "broadcast_archive",
                    action: "save",
                    phase: .completed,
                    properties: ["file_size_bytes": "\(bytes)"]
                )
            } else {
                LiveStreamLog.engine.warning(
                    "archive finalized empty — no segments were captured path=\(url.path, privacy: .public)"
                )
            }
        }
        withLifecycleLock {
            state.withLock { pipeline in
                pipeline = PipelineState(liveState: .stopping)
            }
            try? transition { _ in failure.map(LiveStreamState.failed) ?? .stopped(reason: reason) }
        }
        VisibilityDiagnostics.trackFeatureAction(
            surface: .liveStreaming,
            feature: "broadcast",
            action: "stop",
            phase: .completed,
            properties: [
                "source": "\(reason)",
                "item_count": "\(deliveredSegmentCount)"
            ]
        )
    }

    // MARK: - Audio interruption handling

    /// Mark the encoder paused due to an external audio interruption
    /// (phone call, Siri, alarm, route change, etc.).
    ///
    /// Incoming buffers are dropped while paused — the listener hears the
    /// gap as silence rather than processing stale or partial samples that
    /// would later glitch when the broadcaster's mic re-attaches. The
    /// session itself stays live so the listener's manifest stays open.
    ///
    /// The host is responsible for calling this from
    /// `AVAudioSession.interruptionNotification` (iOS) — the kit stays
    /// platform-agnostic.
    public func handleAudioInterruptionBegan() {
        let wasInterrupted = state.withLock { pipeline -> Bool in
            guard case .live = pipeline.liveState else { return true }
            let prior = pipeline.isInterrupted
            pipeline.isInterrupted = true
            if !prior { pipeline.interruptionStartedAt = Date() }
            return prior
        }
        if !wasInterrupted {
            LiveStreamLog.lifecycle.info("audio interruption began — dropping buffers")
        }
    }

    /// Mark the encoder ready to accept buffers again after an
    /// interruption. If the interruption lasted long enough that the
    /// upstream tap may have changed format on us, we tear the pipeline
    /// build state down so the next buffer rebuilds cleanly.
    public func handleAudioInterruptionEnded() {
        let pauseDuration: TimeInterval = state.withLock { pipeline in
            guard pipeline.isInterrupted else { return 0 }
            let duration = pipeline.interruptionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            pipeline.isInterrupted = false
            pipeline.interruptionStartedAt = nil
            // If we paused for more than 2 seconds the input device may
            // have changed (route change during a call), so blow away the
            // pipeline state. Next buffer through will rebuild with the
            // new sample rate / channel count.
            if duration >= 2.0 {
                pipeline.sourceFormat = nil
                pipeline.downmixer = nil
                pipeline.aiMixProcessor = nil
                pipeline.encoder = nil
                // Keep the segmenter: sequence numbers belong to the session,
                // not to the upstream audio route or encoder instance.
            }
            return duration
        }
        LiveStreamLog.lifecycle.info(
            "audio interruption ended pauseSeconds=\(pauseDuration, privacy: .public) pipelineRebuild=\(pauseDuration >= 2.0, privacy: .public)"
        )
    }

    /// Best-effort cleanup hook for app termination. The host calls this
    /// from `applicationWillTerminate` (or the scene equivalent) so the
    /// backend doesn't keep the session marked "live" forever after a
    /// force-quit. The system gives us only a few seconds and may kill
    /// us mid-call, so this is fire-and-forget.
    public func handleAppWillTerminate() async {
        LiveStreamLog.lifecycle.warning("app will terminate — attempting graceful stop")
        await stop(reason: .appBackgrounded)
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
        case .live:
            break
        default:
            return
        }
        // Drop buffers while an audio interruption is active. We keep the
        // session in `.live` so the listener's manifest stays open; they
        // hear silence until we resume.
        if state.withLock(\.isInterrupted) { return }

        // One-shot log of the first buffer that survives the state guard.
        // Without this it's hard to tell whether "no audio reached the
        // listener" was a pipeline-build failure, a state-transition race,
        // or the recorder never fanning out anything.
        let isFirstBuffer: Bool = state.withLock { pipeline in
            if pipeline.hasReceivedFirstBuffer { return false }
            pipeline.hasReceivedFirstBuffer = true
            return true
        }
        if isFirstBuffer {
            LiveStreamLog.engine.info(
                "first buffer received sampleRate=\(buffer.format.sampleRate, privacy: .public) channels=\(buffer.format.channelCount, privacy: .public) frames=\(buffer.frameLength, privacy: .public)"
            )
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
                    let (segmentIndex, archive): (Int, LiveStreamArchive?) = state.withLock { pipeline in
                        pipeline.segmentsEncoded += 1
                        return (pipeline.segmentsEncoded, pipeline.archive)
                    }
                    // Throttle to first 3 segments + every 15th — enough to
                    // confirm the pipeline is alive without spamming.
                    if segmentIndex <= 3 || segmentIndex.isMultiple(of: 15) {
                        LiveStreamLog.engine.debug(
                            "segment encoded seq=\(segment.sequence, privacy: .public) bytes=\(segment.data.count, privacy: .public) duration=\(segment.duration, privacy: .public) total=\(segmentIndex, privacy: .public)"
                        )
                    }
                    onEvent(.segmentEncoded(
                        sequence: segment.sequence,
                        bytes: segment.data.count,
                        duration: segment.duration
                    ))
                    // Mirror to the local archive in parallel with the
                    // upload. Each segment is already a valid sequence of
                    // ADTS frames, so concatenating them yields a playable
                    // AAC file. Archive writes are best-effort — never fail
                    // the live path on a disk error.
                    state.withLock { pipeline in
                        let previous = pipeline.deliveryTask
                        pipeline.deliveryTask = Task {
                            await previous?.value
                            if let archive { await archive.append(segment.data) }
                            await uploader.enqueue(segment)
                        }
                    }
                }
            }
        } catch {
            LiveStreamLog.engine.error("encode failed error=\(String(describing: error), privacy: .public)")
            handleEncodingFailure(.encoderFailed(String(describing: error)))
        }
    }

    // Move the actual engine into shutdown, rather than only telling the UI
    // it failed while encoding and uploading keep running behind the error.
    func handleEncodingFailure(_ error: LiveStreamError) {
        guard claimStop() else { return }
        Task { await self.finishStop(reason: .requested, failure: error) }
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
        ) else {
            LiveStreamLog.engine.error(
                "pipeline build failed at downmixer sampleRate=\(inputSampleRate, privacy: .public) channels=\(inputChannelCount, privacy: .public)"
            )
            return
        }
        guard let encoder = AACEncoder(
            sourceFormat: downmixer.outputFormat,
            sampleRate: config.sampleRate,
            bitrate: config.stereoBitrate
        ) else {
            LiveStreamLog.engine.error(
                "pipeline build failed at encoder targetSampleRate=\(self.config.sampleRate, privacy: .public) bitrate=\(self.config.stereoBitrate, privacy: .public)"
            )
            return
        }
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
            // Input formats can change mid-session; keep the existing HLS
            // sequence and pending encoded audio across an encoder rebuild.
            if pipeline.segmenter == nil { pipeline.segmenter = segmenter }
        }
        LiveStreamLog.engine.info(
            "pipeline ready inputRate=\(inputSampleRate, privacy: .public) inputChannels=\(inputChannelCount, privacy: .public) outputRate=\(self.config.sampleRate, privacy: .public) bitrate=\(self.config.stereoBitrate, privacy: .public) segmentDuration=\(self.config.segmentDuration, privacy: .public) aiMix=\(self.config.aiMixMode == .off ? "off" : "broadcastPolish", privacy: .public)"
        )
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

    private func withLifecycleLock<T>(_ operation: () throws -> T) rethrows -> T {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return try operation()
    }

    private func endOrphanSession(_ session: LiveStreamSession) async {
        // A cancelled start must still notify the backend. An unstructured task
        // gives cleanup its own cancellation lifetime and the client's timeout.
        await Task { [client] in try? await client.endSession(session) }.value
    }

    private func isPreparing(_ generation: UUID) -> Bool {
        state.withLock { $0.generation == generation && $0.liveState == .preparing }
    }

    private func onEvent(_ event: LiveStreamEvent, generation: UUID) {
        withLifecycleLock {
            guard state.withLock({ $0.generation == generation }) else { return }
            onEvent(event)
            if case .sessionStatusChanged(let status) = event,
               ["ended", "failed"].contains(status.lowercased()), claimStop() {
                // Backend idle expiry or an operator stop is authoritative.
                // Stop ingesting rather than endlessly retrying terminal 409s.
                Task { await self.finishStop(reason: .backendClosed) }
            }
        }
    }

    // Internal so tests can await processing without timing-dependent sleeps.
    func flushProcessingQueue() async {
        await withCheckedContinuation { continuation in
            processingQueue.async { continuation.resume() }
        }
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
            if next != old {
                LiveStreamLog.engine.info(
                    "state \(String(describing: old), privacy: .public) → \(String(describing: next), privacy: .public)"
                )
                onEvent(.stateChanged(next))
            }
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

    // MARK: - Health monitor

    /// Thresholds for the periodic health check. The numbers are tuned to
    /// our default 4-second segment cadence — anything materially shorter
    /// than `degradedEncodeStaleSeconds` would false-positive while the
    /// first segment is still being assembled.
    private enum HealthThresholds {
        /// No segment encoded for this many seconds → encode pipeline is
        /// stalled (recorder paused, AVAudioSession yanked, etc.).
        static let degradedEncodeStaleSeconds: TimeInterval = 12
        /// Segments are encoding but uploads aren't landing → backend or
        /// network problem.
        static let degradedUploadStaleSeconds: TimeInterval = 10
        /// Either staleness this long → failing. Listener experience is
        /// almost certainly broken; broadcaster should restart.
        static let failingStaleSeconds: TimeInterval = 30
    }

    private func startHealthMonitor() {
        stopHealthMonitor()
        healthMonitorTask = Task { [weak self] in
            // Sleep 5s between checks. Faster polling buys nothing — the
            // segment cadence is already 4s minimum.
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                guard let self else { return }
                self.evaluateHealth()
            }
        }
    }

    private func stopHealthMonitor() {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        // Reset published health so the broadcaster UI returns to neutral
        // for the next session.
        state.withLock { pipeline in
            pipeline.lastHealth = .healthy
            pipeline.lastEncodeAt = nil
            pipeline.lastUploadAt = nil
        }
    }

    func evaluateHealth(at now: Date = Date()) {
        withLifecycleLock { evaluateHealthSnapshot(at: now) }
    }

    private func evaluateHealthSnapshot(at now: Date) {
        let snapshot: (LiveStreamHealth, Date?, Date?, Bool, LiveStreamState) = state.withLock { pipeline in
            (pipeline.lastHealth, pipeline.lastEncodeAt, pipeline.lastUploadAt, pipeline.isInterrupted, pipeline.liveState)
        }
        // Only evaluate while we're actually live. Preparing has no audio
        // expectation yet; stopping is mid-flush.
        guard case .live(_, let since) = snapshot.4 else { return }
        // Interruptions are an expected pause — don't penalize for them.
        if snapshot.3 { return }

        let priorHealth = snapshot.0
        // Absence of the first segment/upload ages from session start.
        // Infinity both hid sessions with no audio forever and trapped when
        // the first encode preceded the first upload (Int(infinity)).
        let encodeAgo = max(0, now.timeIntervalSince(snapshot.1 ?? since))
        let uploadAgo = max(0, now.timeIntervalSince(snapshot.2 ?? since))

        let (newHealth, reason): (LiveStreamHealth, String) = {
            if encodeAgo >= HealthThresholds.failingStaleSeconds {
                return (.failing, "no audio encoded in \(Int(encodeAgo))s")
            }
            if uploadAgo >= HealthThresholds.failingStaleSeconds {
                return (.failing, "no upload landed in \(Int(uploadAgo))s")
            }
            if encodeAgo >= HealthThresholds.degradedEncodeStaleSeconds {
                return (.degraded, "encode stalled \(Int(encodeAgo))s")
            }
            if uploadAgo >= HealthThresholds.degradedUploadStaleSeconds {
                return (.degraded, "uploads stalled \(Int(uploadAgo))s")
            }
            return (.healthy, "")
        }()

        guard newHealth != priorHealth else { return }
        state.withLock { $0.lastHealth = newHealth }
        LiveStreamLog.engine.info(
            "health \(String(describing: priorHealth), privacy: .public) → \(String(describing: newHealth), privacy: .public) reason=\(reason, privacy: .public)"
        )
        VisibilityDiagnostics.recordBreadcrumb(
            category: "LiveStreaming",
            message: "stream_health_changed",
            level: newHealth == .healthy ? .info : .warning,
            properties: [
                "source": "\(priorHealth)",
                "action_status": "\(newHealth)",
                "error_message": reason
            ]
        )
        if newHealth == .failing {
            VisibilityDiagnostics.trackFeatureAction(
                surface: .liveStreaming,
                feature: "broadcast",
                action: "health_check",
                phase: .failed,
                properties: ["error_message": reason]
            )
        }
        onEvent(.streamHealthChanged(newHealth, reason: reason))
    }

    private func mapStartError(_ error: Error) -> LiveStreamError {
        // Pass-through precise cases (notAuthenticated, backendRejected, etc.)
        // set by `LiveStreamClient.ensureSuccess`; otherwise fall through to
        // the shared transport-error mapper, which distinguishes "offline" /
        // "timed out" / "TLS failed" from generic backendUnreachable.
        mapLiveStreamTransportError(error, baseURL: config.ingestBaseURL)
    }
}

import Foundation
@preconcurrency import AVFoundation

/// A single-use video broadcast and independent local recording. Capture remains
/// the host's responsibility so its existing multitrack audio tap stays authoritative.
public final class LiveVideoBroadcaster: @unchecked Sendable {
    public let configuration: LiveVideoConfiguration
    public let archiveDirectoryURL: URL?
    public var archivePlaylistURL: URL? { archiveDirectoryURL?.appendingPathComponent("index.m3u8") }

    private let onEvent: @Sendable (LiveVideoEvent) -> Void
    private let lock = NSRecursiveLock()
    private let outputQueue = DispatchQueue(label: "carnyx.live-video.output", qos: .utility)
    private var currentState: LiveVideoState = .idle
    private var writer: FragmentedMP4Writer?
    private var failure: LiveVideoError?
    private var recordingFailure: LiveVideoError?
    private var networkFailure: LiveVideoError?
    private var pendingOutputCount = 0
    private var stopTask: Task<Void, Error>?
    // Archive is confined to outputQueue after initialization.
    private var archive: LiveVideoArchive?
    private var delivery: LiveVideoDelivery?

    public var state: LiveVideoState { lock.withLock { currentState } }
    /// Set as soon as a requested archive becomes unavailable. Streaming may
    /// continue, but stop() will report this save failure to its caller.
    public var archiveError: LiveVideoError? { lock.withLock { recordingFailure } }
    public var deliveryError: LiveVideoError? { lock.withLock { networkFailure } }

    /// The caller retains security-scoped access to parentDirectory until stop()
    /// completes. A fresh owned subdirectory is created; existing files are untouched.
    public init(
        configuration: LiveVideoConfiguration = .init(),
        archiveParentDirectory: URL? = nil,
        sink: (any LiveVideoSegmentSink)? = nil,
        onEvent: @escaping @Sendable (LiveVideoEvent) -> Void = { _ in }
    ) throws {
        try configuration.validate()
        guard archiveParentDirectory != nil || sink != nil else {
            throw LiveVideoError.invalidConfiguration("Choose a local archive or a video-capable stream sink")
        }
        self.configuration = configuration
        self.onEvent = onEvent
        let archive = try archiveParentDirectory.map { try LiveVideoArchive(parentDirectory: $0, configuration: configuration) }
        self.archive = archive
        archiveDirectoryURL = archive?.directoryURL
        delivery = sink.map { sink in
            LiveVideoDelivery(sink: sink, maxPendingSegments: configuration.maxPendingSegments) { [weak self] event in
                self?.handleDeliveryEvent(event)
            }
        }
    }

    /// Start against the same host clock used by camera frames and audio tap time.
    /// Never independently zero audio and video timestamps.
    public func start(at hostTime: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) throws {
        try lock.withLock {
            guard currentState == .idle else {
                throw LiveVideoError.invalidState("Create a new broadcaster for each recording")
            }
            writer = try FragmentedMP4Writer(
                configuration: configuration, epoch: hostTime,
                onSegment: { [weak self] in self?.enqueueOutput($0) },
                onFailure: { [weak self] in self?.fail($0) },
                onDrop: { [weak self] in self?.onEvent(.sampleDropped($0)) }
            )
            currentState = .recording
            onEvent(.stateChanged(.recording))
        }
    }

    @discardableResult
    public func appendVideo(_ sampleBuffer: CMSampleBuffer, at hostTime: CMTime) -> Bool {
        let active = lock.withLock { currentState == .recording ? writer : nil }
        return active?.appendVideo(sampleBuffer, at: hostTime) ?? false
    }

    @discardableResult
    public func appendAudio(_ sampleBuffer: CMSampleBuffer, at hostTime: CMTime) -> Bool {
        let active = lock.withLock { currentState == .recording ? writer : nil }
        return active?.appendAudio(sampleBuffer, at: hostTime) ?? false
    }

    /// Convenience for an already mixed PCM tap. Missing host time is an error,
    /// rather than a guessed alignment based on callback arrival time.
    @discardableResult
    public func appendAudio(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) throws -> Bool {
        let sample = try LiveVideoAudioSample.make(buffer: buffer, at: time)
        return appendAudio(sample, at: CMClockMakeHostTimeFromSystemUnits(time.hostTime))
    }

    /// Finalizes the local recording before waiting on network delivery. Pass
    /// drainDelivery:false to cancel queued uploads. Repeated calls share one stop.
    public func stop(drainDelivery: Bool = true) async throws {
        // A later cancellation can also unblock an earlier stop waiting on a sink.
        if !drainDelivery { await delivery?.cancel() }
        let task: Task<Void, Error> = lock.withLock {
            if let stopTask { return stopTask }
            if currentState == .idle || currentState == .recording {
                currentState = .stopping
                onEvent(.stateChanged(.stopping))
            }
            let task = Task { try await self.finishStop(drainDelivery: drainDelivery) }
            stopTask = task
            return task
        }
        try await task.value
    }

    private func enqueueOutput(_ segment: LiveVideoSegment) {
        let accepted = lock.withLock { () -> Bool in
            guard failure == nil, pendingOutputCount < configuration.maxPendingSegments else { return false }
            pendingOutputCount += 1
            return true
        }
        guard accepted else {
            fail(.archiveFailed("Video output cannot keep up; completed recording fragments were retained"))
            return
        }
        outputQueue.async { [self] in
            defer { lock.withLock { pendingOutputCount -= 1 } }
            if let activeArchive = archive {
                do {
                    try activeArchive.append(segment)
                } catch {
                    // A removed/full drive is visible, never mistaken for a successful save.
                    try? activeArchive.finish(success: false)
                    archive = nil
                    recordArchiveFailure(error)
                }
            }
            delivery?.enqueue(segment)
            if segment.kind == .media {
                onEvent(.segmentProduced(sequence: segment.sequence, bytes: segment.data.count))
            }
        }
    }

    private func finishStop(drainDelivery: Bool) async throws {
        if let writer {
            do { try await writer.finish() }
            catch { fail((error as? LiveVideoError) ?? .encodingFailed(error.localizedDescription)) }
        } else {
            fail(.invalidState("The broadcaster was not started"))
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            outputQueue.async { [self] in
                do { try archive?.finish(success: lock.withLock { failure == nil }) }
                catch { recordArchiveFailure(error) }
                archive = nil
                continuation.resume()
            }
        }
        if drainDelivery, lock.withLock({ failure == nil }) { await delivery?.finish() }
        else { await delivery?.cancel() }
        // The sink's terminal transition can precede its callback notification.
        // Final status must not depend on which thread delivers that event first.
        if let message = delivery?.terminalFailure {
            lock.withLock {
                let mapped = LiveVideoError.deliveryFailed(message)
                networkFailure = networkFailure ?? mapped
                if archiveDirectoryURL == nil || recordingFailure != nil {
                    failure = failure ?? mapped
                }
            }
        }
        let result = lock.withLock { () -> LiveVideoError? in
            writer = nil
            let terminalError = failure ?? recordingFailure
            currentState = terminalError.map(LiveVideoState.failed) ?? .finished
            return terminalError
        }
        if let result {
            onEvent(.stateChanged(.failed(result)))
            throw result
        }
        onEvent(.stateChanged(.finished))
    }

    private func fail(_ error: LiveVideoError) {
        lock.withLock {
            guard failure == nil else { return }
            failure = error
            currentState = .failed(error)
            onEvent(.stateChanged(.failed(error)))
        }
    }

    private func recordArchiveFailure(_ error: Error) {
        let mapped = LiveVideoError.archiveFailed(error.localizedDescription)
        lock.withLock { recordingFailure = recordingFailure ?? mapped }
        onEvent(.archiveFailed(error.localizedDescription))
        if delivery == nil || lock.withLock({ networkFailure != nil }) { fail(mapped) }
    }

    private func handleDeliveryEvent(_ event: LiveVideoEvent) {
        if case .deliveryFailed(_, let message) = event {
            let mapped = LiveVideoError.deliveryFailed(message)
            lock.withLock { networkFailure = networkFailure ?? mapped }
            // With no local recording, a failed network lane leaves no destination.
            if archiveDirectoryURL == nil || lock.withLock({ recordingFailure != nil }) { fail(mapped) }
        }
        onEvent(event)
    }
}

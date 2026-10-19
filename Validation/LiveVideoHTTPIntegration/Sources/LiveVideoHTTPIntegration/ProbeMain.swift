import Foundation
@preconcurrency import AVFoundation
import LiveStreamingVideo
import Darwin

private enum ProbeError: String, Error { case invalidArguments, nonLoopbackURL, invalidStorage, encoding, delivery, samplesDropped }
private struct Credentials: Decodable, Sendable { let base_url: URL; let token: String }

/// Reject every non-loopback request, including object upload destinations.
/// No camera, microphone, cloud storage or live user account is used by this probe.
private final class LoopbackTransport: LiveVideoHTTPTransport, @unchecked Sendable {
    private let transport = LiveVideoURLSessionTransport()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var failedStatuses: [Int] = []

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, isLoopback(url) else { throw ProbeError.nonLoopbackURL }
        let result = try await transport.perform(request)
        let kind: String
        if url.path.contains("capabilities") { kind = "capabilities" }
        else if request.httpMethod == "PUT" { kind = "object_put" }
        else if url.path.hasSuffix("/commit") || url.path.hasSuffix("/commit/") { kind = "object_commit" }
        else if url.path.hasSuffix("/uploads") || url.path.hasSuffix("/uploads/") { kind = "upload_authorization" }
        else if url.path.hasSuffix("/end") || url.path.hasSuffix("/end/") { kind = "session_end" }
        else { kind = "session_create" }
        lock.withLock {
            counts[kind, default: 0] += 1
            if !(200..<300).contains(result.1.statusCode) { failedStatuses.append(result.1.statusCode) }
        }
        return result
    }

    var summary: [String: Int] { lock.withLock { counts } }
    var errors: [Int] { lock.withLock { failedStatuses } }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var produced = 0
    private var delivered = 0
    private var dropped = 0
    private var audioDropped = 0
    private var videoDropped = 0
    private var failures = 0
    func append(_ event: LiveVideoEvent) {
        lock.withLock {
            switch event {
            case .segmentProduced: produced += 1
            case .segmentDelivered: delivered += 1
            case .sampleDropped(let mediaType):
                dropped += 1
                if mediaType == .audio { audioDropped += 1 } else { videoDropped += 1 }
            case .deliveryDropped: dropped += 1
            case .archiveFailed, .deliveryFailed, .stateChanged(.failed): failures += 1
            default: break
            }
        }
    }
    var summary: [String: Int] {
        lock.withLock { ["segments_produced": produced, "segments_delivered": delivered, "samples_or_segments_dropped": dropped,
                         "audio_samples_dropped": audioDropped, "video_samples_dropped": videoDropped, "failures": failures] }
    }
}

private func isLoopback(_ url: URL) -> Bool {
    url.scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host ?? "") && url.user == nil && url.password == nil
}

private func writeJSON(_ value: [String: Any], to url: URL) throws {
    let bytes = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try bytes.write(to: url, options: .withoutOverwriting)
}

@main
private enum ProbeMain {
    static func main() async {
        var phase = "arguments"
        var output: URL?
        var client: LiveVideoHTTPClient?
        var remote: LiveVideoHTTPSession?
        var broadcaster: LiveVideoBroadcaster?
        let transport = LoopbackTransport()
        let events = Events()
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count.isMultiple(of: 2) else { throw ProbeError.invalidArguments }
            var values: [String: String] = [:]
            for index in stride(from: 0, to: arguments.count, by: 2) { values[arguments[index]] = arguments[index + 1] }
            guard let credentialsPath = values["--credentials"], let outputPath = values["--output-root"],
                  let seconds = Int(values["--seconds"] ?? "8"), (6...20).contains(seconds) else { throw ProbeError.invalidArguments }
            let credentials = try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: URL(fileURLWithPath: credentialsPath)))
            guard isLoopback(credentials.base_url), !credentials.token.isEmpty else { throw ProbeError.nonLoopbackURL }
            let root = URL(fileURLWithPath: outputPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw ProbeError.invalidStorage }
            let run = root.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)
            output = run
            let activeClient = LiveVideoHTTPClient(configuration: .init(
                baseURL: credentials.base_url, authToken: { credentials.token },
                requestTimeout: 15, maximumAttempts: 3, allowInsecureLoopback: true
            ), transport: transport)
            client = activeClient
            let configuration = LiveVideoConfiguration(
                videoWidth: 720, videoHeight: 1280, framesPerSecond: 30, videoBitrate: 3_000_000,
                audioSampleRate: 48_000, audioChannelCount: 2, audioBitrate: 128_000,
                segmentDuration: 2, maxPendingSamples: 12, maxPendingSegments: 15
            )
            phase = "session_create"
            let session = try await activeClient.createSession(video: configuration, title: "Carnyx local synthetic video validation")
            remote = session
            phase = "capture"
            let active = try LiveVideoBroadcaster(configuration: configuration, archiveParentDirectory: run,
                                                  sink: activeClient.sink(for: session), onEvent: events.append)
            broadcaster = active
            let epoch = CMClockGetTime(CMClockGetHostTimeClock())
            try active.start(at: epoch)
            let clock = ContinuousClock()
            let started = clock.now
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
            for frame in 0..<(seconds * 30) {
                try await clock.sleep(until: started.advanced(by: .nanoseconds(Int64(frame) * 1_000_000_000 / 30)))
                // Capture starts after the broadcaster epoch, just as a real device
                // delivers its first buffer after start. A buffer exactly at epoch
                // can round a few nanoseconds backwards through host-time units.
                let time = epoch + CMTime(value: Int64(frame + 1), timescale: 30)
                let audio = try makeAudio(frame: frame, format: format)
                guard try active.appendAudio(audio, at: AVAudioTime(hostTime: CMClockConvertHostTimeToSystemUnits(time))) else { throw ProbeError.encoding }
                guard active.appendVideo(try makeVideo(frame: frame, time: time), at: time) else { throw ProbeError.encoding }
            }
            phase = "finalize_and_drain"
            try await active.stop()
            guard active.archiveError == nil, active.deliveryError == nil,
                  active.state == .finished else { throw ProbeError.delivery }
            let metrics = events.summary
            guard metrics["samples_or_segments_dropped"] == 0, metrics["failures"] == 0,
                  metrics["segments_produced"] == metrics["segments_delivered"],
                  (metrics["segments_delivered"] ?? 0) >= 3 else { throw ProbeError.samplesDropped }
            guard let archive = active.archiveDirectoryURL else { throw ProbeError.invalidStorage }
            phase = "export"
            let exported = try await LiveVideoArchiveExporter.export(archiveDirectory: archive, to: run.appendingPathComponent("synthetic-video.mp4"))
            let result: [String: Any] = [
                "passed": true, "session_id": session.id, "archive_directory": archive.path, "export_file": exported.path,
                "seconds": seconds, "video_width": 720, "video_height": 1280, "frames_per_second": 30,
                "audio_sample_rate": 48_000, "audio_channels": 2, "events": metrics,
                "http_requests": transport.summary, "http_failed_statuses": transport.errors,
                "archive_error": false, "delivery_error": false, "synthetic_only": true, "loopback_only": true
            ]
            try writeJSON(result, to: run.appendingPathComponent("capture.json"))
            print("Synthetic capture, upload and MP4 export passed. Evidence: \(run.path)/capture.json")
        } catch {
            if let broadcaster { try? await broadcaster.stop(drainDelivery: false) }
            if let remote, let client { try? await client.endSession(remote) }
            if let output {
                try? writeJSON(["passed": false, "phase": phase, "error_type": String(reflecting: type(of: error)),
                                "probe_failure": (error as? ProbeError)?.rawValue ?? "unexpected",
                                "events": events.summary, "http_requests": transport.summary,
                                "http_failed_statuses": transport.errors], to: output.appendingPathComponent("failure.json"))
            }
            // Never print Error descriptions or URLs: transport errors can carry
            // bearer tokens, ingest credentials and private object capabilities.
            FileHandle.standardError.write(Data("Integration probe failed during \(phase); consult sanitized evidence.\n".utf8))
            exit(1)
        }
    }

    private static func makeAudio(frame: Int, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let audio = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600), let channels = audio.floatChannelData else { throw ProbeError.encoding }
        audio.frameLength = 1600
        for channel in 0..<2 {
            let frequency = channel == 0 ? 440.0 : 660.0
            for sample in 0..<1600 {
                channels[channel][sample] = Float(sin(2 * .pi * frequency * Double(frame * 1600 + sample) / 48_000) * 0.15)
            }
        }
        return audio
    }

    private static func makeVideo(frame: Int, time: CMTime) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 720, 1280, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess,
              let pixels else { throw ProbeError.encoding }
        CVPixelBufferLockBaseAddress(pixels, [])
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { throw ProbeError.encoding }
        let words = CVPixelBufferGetBytesPerRow(pixels) / 4
        let pointer = base.assumingMemoryBound(to: UInt32.self)
        pointer.initialize(repeating: 0xFF202040, count: words * 1280)
        let column = (frame * 7) % 600
        for row in 0..<1280 {
            pointer.advanced(by: row * words + column).update(repeating: row < 640 ? 0xFF40D080 : 0xFF8060E0, count: 120)
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &description) == noErr,
              let description else { throw ProbeError.encoding }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                        formatDescription: description, sampleTiming: &timing,
                                                        sampleBufferOut: &sample) == noErr, let sample else { throw ProbeError.encoding }
        return sample
    }
}

# Opt-in camera video

`LiveStreamingVideo` adds a single-camera H.264/AAC fragmented MP4 pipeline for iOS 18+, Mac Catalyst, and macOS 14+. It is a separate product with no third-party dependencies. Existing `LiveStreamingKit` audio APIs, ADTS segments, and backend requests are unchanged.

The default rendition is landscape 1920×1080 at 30 fps, 5 Mbps H.264, 48 kHz stereo AAC at 128 kbps, in four-second HLS segments. These are configuration defaults, not a claim that a particular iPad/camera/hub/drive combination has passed a sustained capture test.

## Pipeline

```
VideoCaptureKit camera frames ─┐
                             ├─ shared host timestamps → H.264/AAC fMP4 writer
host's mixed PCM audio tap ───┘                           ├─ local HLS archive
                                                         └─ bounded video sink
RecordKit continues saving isolated audio stems independently.
```

`VideoCaptureKit` is the additive camera-source product in the VideoKit repository. It supports an explicitly selected built-in or external UVC camera and supplies sample buffers with timestamps converted to `CMClockGetHostTimeClock()`. A physical clip-on lens is optical and requires no special streaming implementation.

## Host integration

Add the `LiveStreamingVideo` and `VideoCaptureKit` products to the host. Permission UX and a security-scoped directory access lease belong to the host; keep that lease alive until `stop()` returns. Request/check camera permission before starting the pipeline. Add `NSCameraUsageDescription`, the sandboxed Mac camera entitlement, and `NSCameraUseExternalDeviceType=true` for Catalyst external-camera discovery.

```swift
import AVFoundation
import LiveStreamingVideo
import VideoCaptureKit

// selectedDirectory is a user-authorized local directory, optionally on an SSD.
let broadcast = try LiveVideoBroadcaster(
    archiveParentDirectory: selectedDirectory,
    sink: nil, // Recording only; supply a video-capable sink to also broadcast.
    onEvent: { event in /* dispatch status updates to the host UI */ }
)
let camera = CameraFrameSource(
    onFrame: { frame in
        broadcast.appendVideo(frame.sampleBuffer, at: frame.hostPresentationTime)
    },
    onEvent: { event in /* surface camera loss/interruption and stop this take */ }
)
try broadcast.start()
try await camera.start(configuration: CameraCaptureConfiguration(selection: .builtInBack))

// From the host's already mixed audio tap, preserving the tap's AVAudioTime:
// try broadcast.appendAudio(mixedPCMBuffer, at: audioTime)

// Stop sources before finalizing their encoder.
await camera.stop()
try await broadcast.stop(drainDelivery: false)
```

For an external camera, choose `.external(uniqueID: ...)` from `CameraFrameSource.availableCameras()`. A missing selected camera fails; there is no silent substitution. An HDMI camera needs a compatible UVC capture device. Keep rotation fixed for a take; a 90°/270° output requires swapped encoder dimensions.

The PCM input must already match the configured channel count and sample rate (44.1 or 48 kHz, mono or stereo). This product does not own the audio engine, choose audio devices, downmix multichannel stems, run AI processing, or resample a route. In particular, the old `AudioBufferObserver` cumulative frame cursor is **not** a host timestamp and cannot synchronize camera video. The app must preserve `AVAudioTime.hostTime` from its audio tap. Raw CMSampleBuffer input is also supported when its first-sample host time is supplied explicitly.

Callbacks must return promptly and must not synchronously wait on another thread that needs broadcaster state. Do not launch a Task per frame. The writer retains admitted buffers in a bounded queue; rejected/backpressured samples produce `sampleDropped` events. `audioOffset` provides a measured alignment adjustment; it is not automatic lip-sync calibration or hardware clock drift correction.

## Recording and failures

A fresh `Carnyx-LiveVideo-<UUID>` subdirectory contains `init.mp4`, sequential `segment-*.m4s` files, and `index.m3u8`. Existing files are never replaced. Each fragment is synchronized to storage before an atomic playlist update references it. Successful stop drains encoder output and adds `ENDLIST`; failed capture preserves the completed fragments and an open EVENT playlist.

The archive is a standard **HLS bundle**. Preserve the complete directory, including `timeline.json`, which records the original encoded track timestamps before AVFoundation normalizes them independently. After a successful stop, create a standalone shareable MP4 with:

```swift
let mp4URL = try await LiveVideoArchiveExporter.export(
    archiveDirectory: broadcast.archiveDirectoryURL!,
    to: selectedDirectory.appendingPathComponent("Performance.mp4")
)
```

The exporter passes through H.264/AAC without re-encoding, restores relative track timing and the source's AAC priming edit, then removes one common timeline origin. Both positive and negative `audioOffset` corrections survive. Existing destination files are refused. Cancellation throws `CancellationError`; incomplete archives, missing fragments, unavailable storage and export failures throw `LiveVideoError.archiveFailed`. Failed attempts retain the original archive and remove only their own scratch directory. Keep directory access leases alive until export returns. Export currently needs temporary storage alongside the destination for a concatenation and the finished MP4: budget approximately twice the archive's size in additional free space.

This is buffered HLS delivery, targeting roughly 10–20 seconds of end-to-end latency after app/server/player integration and measurement. It is not WebRTC or an interactive sub-second transport. A clip-on lens requires no special encoding behavior. For portrait capture, rotate the camera's actual buffers, configure the encoder with their resulting dimensions (for example 1080×1920), and keep orientation fixed throughout the take. The exporter preserves a source track transform but cannot correct an incorrectly oriented source.

Network failure/overflow permanently stops that delivery lane and reports it; local archival continues. This prevents publishing media after an unrepresented sequence gap. A sink may implement bounded retries within `send`, and must honor cancellation. Initialization must be acknowledged before media; all calls are ordered. `deliveryError` remains readable even when the archive completes successfully.

Drive removal/write failure is surfaced immediately through `archiveFailed` and `archiveError`; `stop()` throws instead of claiming a successful save. With no stream sink, loss of the archive fails the take. With a sink, video can continue streaming. If there is no archive and the sink fails, the take fails. The host should stop capture on terminal failure or camera interruption/disconnection and start a fresh take on reconnection. Automatic resume or mixing camera formats within one stream is intentionally unsupported.

Repeated `stop()` calls share finalization. `stop(drainDelivery: false)` cancels network work, including a previously requested network drain, after which local finalization can return. Storage errors retain previously written files; the library does not erase, eject, remount, or recreate a disconnected volume.

## Backend boundary

The deployed audio ingest contract accepts AAC/ADTS and serves `.aac` files. **It does not support this video output.** There is deliberately no adapter that sends MP4 bytes through `LiveStreamClient` or merely changes its `codec` string.

`LiveVideoHTTPClient` implements the new opt-in `direct-upload-v1` contract. It requires the server's `h264-aac-fmp4-v1` capability before creating a video session. Each initialization/media object is authorized with its exact byte count and SHA-256, uploaded directly to private storage with the returned immutable-write headers, then committed through the API. A segment is acknowledged only after server verification. Retries reconcile an already-uploaded object after a lost response; conflicts and revoked permissions fail permanently. Account/ingest credentials never accompany the storage PUT, and automatic HTTP redirects are disabled.

```swift
let client = LiveVideoHTTPClient(configuration: .init(
    baseURL: apiURL, authToken: { await account.accessToken }
))
let configuration = LiveVideoConfiguration(videoWidth: 720, videoHeight: 1280,
    videoBitrate: 3_000_000, segmentDuration: 2)
let session = try await client.createSession(video: configuration, title: "venue")
let broadcaster = try LiveVideoBroadcaster(configuration: configuration,
    archiveParentDirectory: leasedRecordingDirectory, sink: client.sink(for: session))
```

`LiveVideoFrameRenderer` center-crops camera frames into the exact encoder canvas without inventing a new clock. Use VideoCaptureKit's explicit rotation for a physically rotated camera; landscape sources remain upright and crop to portrait. The app must retain its recording destination lease through finalization and reacquire source access for later MP4 exports.

Private media URLs in a playlist expire independently of its playback grant. `LiveListenerPlaybackGrant.mediaURLRefreshAfterSeconds` tells players when to reauthorize/reload, preserving replay position and pause state. Legacy audio responses omit this property and retain their existing behavior. This is buffered broadcast HLS, with an initial application target of approximately 10–20 seconds, not a subsecond interactive transport. Preserve the existing audio endpoint and keep video disabled until the matching backend/player and actual hardware are qualified.

## Verification

```
swift test --package-path Validation/LiveStreamingVideo
```

The validation manifest references the same production sources and tests through relative symlinks, without resolving the unrelated audio dependency graph. Tests perform actual H.264/AAC encoding and decoding, inspect raw fragment timestamps, and simulate slow/failing delivery, unavailable storage, queue pressure, startup/stop, and input format/timing errors. Export tests decode the real media edits, verify ±250 ms audio correction without a ten-second lead-in, preserve source bytes, cancel an active copy, reject overwrites and exercise storage write failures. On macOS, an installed `ffprobe` also independently checks actual MP4 track start times. Set `LIVE_VIDEO_EXPORT_FIXTURE_DIRECTORY` to a fresh output directory to retain three offset fixtures for independent `ffprobe`/`ffmpeg` inspection. VideoCaptureKit has its own hardware-free test target and cross-platform compile checks.

The app integration and backend/player branches must be released together before enabling video. Sustained physical iPad/Mac qualification is still required: camera disconnect, SSD unplug/full volume, network outages, interruption/backgrounding, thermal load, frame drops, long-session drift, and measured lip sync on the actual powered hub/audio interface/camera/SSD rig. No synthetic test substitutes for that hardware qualification.

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

The archive is a standard **HLS bundle**, not a standalone shareable MP4. Preserve the complete directory. Offline playback integration and a timing-aware single-file export belong to the host's next integration step. Do not concatenate fragments and export them naively: Apple HLS uses a positive timestamp offset for AAC priming, and opening a concatenation as an ordinary MP4 can normalize tracks independently and discard their relative timing.

Network failure/overflow permanently stops that delivery lane and reports it; local archival continues. This prevents publishing media after an unrepresented sequence gap. A sink may implement bounded retries within `send`, and must honor cancellation. Initialization must be acknowledged before media; all calls are ordered. `deliveryError` remains readable even when the archive completes successfully.

Drive removal/write failure is surfaced immediately through `archiveFailed` and `archiveError`; `stop()` throws instead of claiming a successful save. With no stream sink, loss of the archive fails the take. With a sink, video can continue streaming. If there is no archive and the sink fails, the take fails. The host should stop capture on terminal failure or camera interruption/disconnection and start a fresh take on reconnection. Automatic resume or mixing camera formats within one stream is intentionally unsupported.

Repeated `stop()` calls share finalization. `stop(drainDelivery: false)` cancels network work, including a previously requested network drain, after which local finalization can return. Storage errors retain previously written files; the library does not erase, eject, remount, or recreate a disconnected volume.

## Backend boundary

The deployed audio ingest contract accepts AAC/ADTS and serves `.aac` files. **It does not support this video output.** There is deliberately no adapter that sends MP4 bytes through `LiveStreamClient` or merely changes its `codec` string.

Before enabling video in Carnyx, add a capability-negotiated server contract with initialization upload/acknowledgment, immutable media sequence uploads, `video/mp4` serving, H.264/AAC metadata and combined bitrate, `EXT-X-MAP` manifests, and video listener UI. Implement `LiveVideoSegmentSink` only against that contract. Preserve the existing audio endpoint and keep video behind an app feature flag until integration and device qualification pass.

## Verification

```
swift test --package-path Validation/LiveStreamingVideo
```

The validation manifest references the same production sources and tests through relative symlinks, without resolving the unrelated audio dependency graph. Tests perform actual H.264/AAC encoding and decoding, inspect raw fragment timestamps, and simulate slow/failing delivery, unavailable storage, queue pressure, startup/stop, and input format/timing errors. VideoCaptureKit has its own hardware-free test target and cross-platform compile checks.

Still required before shipping the app feature: app audio host-time adapter, backend/player integration, external-directory permission UX, camera selection/preview UI, and sustained physical iPad/Mac tests. Test camera disconnect, SSD unplug/full volume, network outages, interruption/backgrounding, thermal load, frame drops, long-session drift, and measured lip sync on the actual powered hub/audio interface/camera/SSD rig. No synthetic test substitutes for that hardware qualification.

# LiveStreamingKit

Live-native multitrack audio streaming for Carnyx. While `RecordKit` writes isolated stems to disk, `LiveStreamingKit` taps the same input buffers, downmixes to stereo, encodes AAC, packs HLS segments, and uploads them to the mixtape backend — all from the same capture event.

## Overview

```
inputs (n channels)
  ├─► RecordKit (isolated stems on disk)
  └─► LiveStreamingKit (StereoDownmixer ─► optional AIMixKit polish ─► AACEncoder ─► HLSSegmenter ─► Uploader)
```

The session itself is a durable multitrack recording. The livestream is a temporary realtime view of a permanent session.

## Public API

- `LiveStreamEngine` — state machine; owns the encoder/segmenter/uploader; observes audio frames; runs the social poller while live.
- `LiveStreamConfig` — bitrate, sample rate, segment duration, backend endpoint, channel map, optional AI mix mode.
- `LiveStreamSession` — ingest descriptor returned by the backend (id, ingest urls, listener url).
- `LiveStreamState` / `LiveStreamEvent` — emitted on the engine's `onEvent` sink.
- `LiveStreamError` — failure cases.
- `LiveReactionEvent` — single reaction record (id / type / ts) surfaced to broadcaster UI.
- `LiveStreamClient` — auth-aware HTTP client for the livestream backend.
- `AudioBufferObserver` — protocol RecordKit fires per-buffer; `LiveStreamEngine` conforms.

### Engagement events

While a session is live, the engine spins up a `LiveStreamSocialPoller` that watches the backend for listener and reaction activity. It emits these `LiveStreamEvent` cases:

| Case | When |
|---|---|
| `listenerCountChanged(Int)` | Current sliding-window listener count changes |
| `lifetimeListenerStatsChanged(total: Int, peak: Int)` | Lifetime distinct listeners and/or peak concurrent move |
| `reactionTotalsChanged([String: Int])` | Per-type cumulative tallies change |
| `reactionReceived(LiveReactionEvent)` | A single new reaction arrives — emitted exactly once per id |

Defaults: 5s status poll, 1s reactions poll. Failures degrade silently — polling never blocks the audio pipeline. The poller stops automatically on `LiveStreamEngine.stop()`.

The companion `LiveStreamingKitUI` package consumes these via `LiveStreamControlViewModel`.

## Installation

```swift
.package(path: "../LiveStreamingKit")
```

## Testing

XCTest. `swift test` from the package root.

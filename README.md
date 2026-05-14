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

- `LiveStreamEngine` — state machine; owns the encoder/segmenter/uploader; observes audio frames.
- `LiveStreamConfig` — bitrate, sample rate, segment duration, backend endpoint, channel map, optional AI mix mode.
- `LiveStreamSession` — ingest descriptor returned by the backend (id, ingest urls, listener url).
- `LiveStreamState` / `LiveStreamEvent` — async stream consumed by UI.
- `LiveStreamError` — failure cases.
- `AudioBufferObserver` — protocol RecordKit fires per-buffer; `LiveStreamEngine` conforms.

## Installation

```swift
.package(path: "../LiveStreamingKit")
```

## Testing

XCTest. `swift test` from the package root.

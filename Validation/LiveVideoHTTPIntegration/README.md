# Local Django integration probe

This executable feeds synthetic 720 × 1280 H.264 video and stereo AAC audio through
the exact production `LiveVideoBroadcaster` and `LiveVideoHTTPClient` sources.
It uses a shared host-clock timeline, paces eight seconds at 30 fps, uploads through
the server's authorization/PUT/commit protocol, retains an independent local HLS
archive, ends the session and exports an MP4.

It never activates a camera or microphone. Its transport rejects all non-loopback
addresses, including upload URLs. Use an isolated Django fixture server with video
enabled and a throwaway entitled account; this is not a production smoke test.

Store credentials **outside the repository** in a mode-600 JSON file:

```json
{"base_url":"http://127.0.0.1:61986/","token":"<local fixture token>"}
```

Prepare a new, owned output root, then run from this repository:

```sh
swift run --package-path Validation/LiveVideoHTTPIntegration -c release LiveVideoHTTPIntegration \
  --credentials /private/path/credentials.json --output-root /owned/validation-output --seconds 8
python3 Validation/LiveVideoHTTPIntegration/verify.py \
  --credentials /private/path/credentials.json --capture /owned/validation-output/run-UUID/capture.json
```

The verifier requires FFmpeg/FFprobe. It checks that guest grants and unsigned
master/media-playlist/init/segment requests are denied, downloads authorized media without bearer
headers, rewrites the playlist to local filenames, and decodes both tracks in the
HLS replay and exported MP4. It verifies every video frame, portrait dimensions,
stereo audio, duration, start alignment and byte-for-byte agreement between published
media and the independent archive. Signed URLs, grant bodies, bearer tokens and ingest credentials
are never written to reports or printed. Configure the fixture server to omit/redact
query strings in its own access logs as well.

Every invocation creates a fresh `run-UUID` directory and refuses to overwrite its
files. No existing recordings or drive contents are removed. The resulting evidence
proves local HTTP interoperability; it does not verify physical capture, production
GCS permissions/CORS, real network latency or long-running venue behavior.

Verified on macOS on 2026-10-18 with LiveStreamingKit `a668388` and backend
`c890483cf7b5c8e122645dc07a3370cab3612a0d`: eight seconds produced 240 video
frames and five media fragments, with no dropped samples, failed HTTP requests,
archive errors or delivery errors. The downloaded HLS and exported MP4 both
decoded H.264 720 × 1280 at 30 fps and 48 kHz stereo AAC. Guest grants returned
401; unsigned master, media playlist, initialization and segment requests returned
403. HLS track starts differed by 44 ms including AAC priming; the standalone MP4
started both tracks at zero. These are synthetic timing checks, not a physical
camera/microphone synchronization measurement.

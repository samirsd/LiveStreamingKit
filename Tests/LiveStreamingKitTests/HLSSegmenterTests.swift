import XCTest
import AVFoundation
@testable import LiveStreamingKit

final class HLSSegmenterTests: XCTestCase {
    private let sampleRate: Double = 48_000

    func testADTSHeaderForty8KHzStereoMatchesExpectedBytes() throws {
        let header = try XCTUnwrap(ADTSFraming.header(rawAACFrameSize: 200, sampleRate: 48_000, channelCount: 2))
        XCTAssertEqual(header.count, 7)
        // Sync word
        XCTAssertEqual(header[0], 0xFF)
        // Sync + MPEG-4 + no CRC
        XCTAssertEqual(header[1] & 0xF6, 0xF0)
        // Profile bits (AAC-LC = profile 2 → bits 01) and frequency index (3 = 48kHz)
        let profileBits = (header[2] & 0xC0) >> 6
        let freqIndex = (header[2] & 0x3C) >> 2
        XCTAssertEqual(profileBits, 1)
        XCTAssertEqual(freqIndex, 3)
        // Frame length = 200 + 7 = 207; high two bits in byte 3 low two, middle 8 in byte 4, low 3 in byte 5 high 3
        let frameLength = (UInt(header[3] & 0x3) << 11)
            | (UInt(header[4]) << 3)
            | (UInt(header[5] & 0xE0) >> 5)
        XCTAssertEqual(Int(frameLength), 207)
    }

    func testADTSHeaderReturnsNilForUnsupportedSampleRate() {
        XCTAssertNil(ADTSFraming.header(rawAACFrameSize: 100, sampleRate: 1000, channelCount: 2))
    }

    func testSegmenterEmitsSegmentWhenTargetDurationReached() throws {
        let segmenter = HLSSegmenter(targetDuration: 0.064, sampleRate: 48_000, channelCount: 2)
        // Each AAC packet is 1024 frames @ 48kHz → ~21.33ms. 4 packets ≈ 85.3ms > 64ms.
        let payload = Data([0x21, 0x10, 0x05, 0x00])
        let packets = (0..<4).map { index in
            EncodedAACPacket(
                data: payload,
                frameCount: 1024,
                presentationTime: AVAudioFramePosition(index * 1024),
                sampleRate: 48_000
            )
        }
        var emitted: [HLSSegment] = []
        for packet in packets {
            if let segment = segmenter.append(packet) { emitted.append(segment) }
        }
        XCTAssertGreaterThanOrEqual(emitted.count, 1)
        XCTAssertEqual(emitted.first?.sequence, 0)
        // Final segment contains 4 ADTS frames worth of bytes: header(7) + payload(4) per frame
        let firstSegment = try XCTUnwrap(emitted.first)
        XCTAssertGreaterThan(firstSegment.data.count, payload.count * 3)
    }

    func testSegmenterFinishFlushesPartialSegment() {
        let segmenter = HLSSegmenter(targetDuration: 2.0, sampleRate: 48_000, channelCount: 2)
        let packet = EncodedAACPacket(data: Data([1, 2, 3]), frameCount: 1024, presentationTime: 0, sampleRate: 48_000)
        XCTAssertNil(segmenter.append(packet))
        let final = segmenter.finish()
        XCTAssertNotNil(final)
        XCTAssertTrue(final?.isFinalSegment ?? false)
    }

    func testPlaylistBuilderRendersEventManifest() {
        let segments = [
            PlaylistBuilder.SegmentRef(uri: "0.aac", duration: 4.000),
            PlaylistBuilder.SegmentRef(uri: "1.aac", duration: 4.000),
            PlaylistBuilder.SegmentRef(uri: "2.aac", duration: 3.520),
        ]
        let playlist = PlaylistBuilder(targetDuration: 4, mediaSequence: 0, segments: segments, isClosed: false)
        let text = playlist.render()
        XCTAssertTrue(text.contains("#EXTM3U"))
        XCTAssertTrue(text.contains("#EXT-X-TARGETDURATION:4"))
        XCTAssertTrue(text.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        XCTAssertTrue(text.contains("0.aac"))
        XCTAssertTrue(text.contains("#EXTINF:4.000,"))
        XCTAssertFalse(text.contains("#EXT-X-ENDLIST"))
    }

    func testPlaylistBuilderClosesWithEndlist() {
        let playlist = PlaylistBuilder(
            targetDuration: 4,
            mediaSequence: 0,
            segments: [.init(uri: "0.aac", duration: 4)],
            isClosed: true
        )
        XCTAssertTrue(playlist.render().contains("#EXT-X-ENDLIST"))
    }
}

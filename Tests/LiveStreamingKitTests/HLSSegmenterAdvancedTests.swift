import XCTest
import AVFoundation
@testable import LiveStreamingKit

final class HLSSegmenterAdvancedTests: XCTestCase {
    private let sampleRate: Double = 48_000

    func testSegmenterAssignsMonotonicSequenceNumbers() {
        // Each packet ≈ 21.33ms @ 48kHz/1024 frames. Target 0.02s => one segment per packet.
        let segmenter = HLSSegmenter(targetDuration: 0.02, sampleRate: sampleRate, channelCount: 2)
        var emitted: [HLSSegment] = []
        let payload = Data([0x11, 0x22, 0x33])
        for index in 0..<5 {
            let packet = EncodedAACPacket(
                data: payload,
                frameCount: 1024,
                presentationTime: AVAudioFramePosition(index * 1024),
                sampleRate: sampleRate
            )
            if let segment = segmenter.append(packet) {
                emitted.append(segment)
            }
        }
        XCTAssertEqual(emitted.count, 5)
        XCTAssertEqual(emitted.map(\.sequence), [0, 1, 2, 3, 4])
    }

    func testStartingSequenceIsRespected() {
        // Target 0.02s triggers emission after one ~21ms packet.
        let segmenter = HLSSegmenter(
            targetDuration: 0.02,
            sampleRate: sampleRate,
            channelCount: 2,
            startingSequence: 100
        )
        let payload = Data([0xFF])
        let first = segmenter.append(EncodedAACPacket(
            data: payload, frameCount: 1024,
            presentationTime: 0, sampleRate: sampleRate
        ))
        XCTAssertEqual(first?.sequence, 100)
    }

    func testFinishDoesNothingWhenNoPendingFrames() {
        let segmenter = HLSSegmenter(targetDuration: 4.0, sampleRate: sampleRate, channelCount: 2)
        XCTAssertNil(segmenter.finish())
    }

    func testAppendPacketsBatchEmitsZeroOrMore() {
        let segmenter = HLSSegmenter(targetDuration: 0.02, sampleRate: sampleRate, channelCount: 2)
        let packets = (0..<6).map { index in
            EncodedAACPacket(
                data: Data([0x10]),
                frameCount: 1024,
                presentationTime: AVAudioFramePosition(index * 1024),
                sampleRate: sampleRate
            )
        }
        let segments = segmenter.append(packets: packets)
        XCTAssertGreaterThanOrEqual(segments.count, 1)
        // sequenceCursor must advance by the number of emitted segments
        XCTAssertEqual(segmenter.sequenceCursor, segments.count)
    }

    func testFinishMarksFinalSegment() {
        let segmenter = HLSSegmenter(targetDuration: 10.0, sampleRate: sampleRate, channelCount: 2)
        _ = segmenter.append(EncodedAACPacket(
            data: Data([0x10]),
            frameCount: 1024,
            presentationTime: 0,
            sampleRate: sampleRate
        ))
        let last = segmenter.finish()
        XCTAssertNotNil(last)
        XCTAssertTrue(last?.isFinalSegment ?? false)
    }

    func testHLSSegmentEquality() {
        let a = HLSSegment(sequence: 0, data: Data([0x1]), duration: 4)
        let b = HLSSegment(sequence: 0, data: Data([0x1]), duration: 4)
        let c = HLSSegment(sequence: 0, data: Data([0x2]), duration: 4)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

@preconcurrency import AVFoundation
import XCTest
@testable import LiveStreamingVideo

final class LiveVideoAudioSampleTests: XCTestCase {
    func testCopiesPlanarPCMAndPreservesHostTimestamp() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0.25, count: 1024) }
        let host = CMClockGetHostTimeClock()
        let hostTime = CMClockConvertHostTimeToSystemUnits(CMClockGetTime(host))
        let sample = try LiveVideoAudioSample.make(buffer: buffer, at: AVAudioTime(hostTime: hostTime))
        XCTAssertTrue(CMSampleBufferDataIsReady(sample))
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1024)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample), CMClockMakeHostTimeFromSystemUnits(hostTime))
        for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: 0, count: 1024) }
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        var value: Float = 0
        XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &value), noErr)
        XCTAssertEqual(value, 0.25)
    }

    func testRejectsFrameCursorWithoutHostTime() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        XCTAssertThrowsError(try LiveVideoAudioSample.make(buffer: buffer, at: AVAudioTime(sampleTime: 0, atRate: 48_000)))
    }
}

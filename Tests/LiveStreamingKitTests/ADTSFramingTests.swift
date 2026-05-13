import XCTest
@testable import LiveStreamingKit

final class ADTSFramingTests: XCTestCase {

    func testFrequencyIndexCoversCommonSampleRates() {
        XCTAssertEqual(ADTSFraming.samplingFrequencyIndex(for: 96_000), 0)
        XCTAssertEqual(ADTSFraming.samplingFrequencyIndex(for: 88_200), 1)
        XCTAssertEqual(ADTSFraming.samplingFrequencyIndex(for: 64_000), 2)
        XCTAssertEqual(ADTSFraming.samplingFrequencyIndex(for: 48_000), 3)
        XCTAssertEqual(ADTSFraming.samplingFrequencyIndex(for: 44_100), 4)
        XCTAssertEqual(ADTSFraming.samplingFrequencyIndex(for: 32_000), 5)
        XCTAssertEqual(ADTSFraming.samplingFrequencyIndex(for: 24_000), 6)
        XCTAssertEqual(ADTSFraming.samplingFrequencyIndex(for: 22_050), 7)
        XCTAssertEqual(ADTSFraming.samplingFrequencyIndex(for: 16_000), 8)
        XCTAssertEqual(ADTSFraming.samplingFrequencyIndex(for: 12_000), 9)
        XCTAssertEqual(ADTSFraming.samplingFrequencyIndex(for: 11_025), 10)
        XCTAssertEqual(ADTSFraming.samplingFrequencyIndex(for: 8_000), 11)
        XCTAssertEqual(ADTSFraming.samplingFrequencyIndex(for: 7_350), 12)
    }

    func testFrequencyIndexUnsupportedSampleRates() {
        XCTAssertNil(ADTSFraming.samplingFrequencyIndex(for: 100))
        XCTAssertNil(ADTSFraming.samplingFrequencyIndex(for: 192_000))
        XCTAssertNil(ADTSFraming.samplingFrequencyIndex(for: 0))
    }

    func testHeader44100MonoEncodesFrequencyIndexAndChannelConfig() throws {
        let header = try XCTUnwrap(ADTSFraming.header(rawAACFrameSize: 100, sampleRate: 44_100, channelCount: 1))
        let freqIndex = (header[2] & 0x3C) >> 2
        let channelConfig = ((header[2] & 0x1) << 2) | ((header[3] & 0xC0) >> 6)
        XCTAssertEqual(freqIndex, 4)
        XCTAssertEqual(channelConfig, 1)
    }

    func testHeaderFrameLengthExceedsThirteenBitsReturnsNil() {
        let oversized = (1 << 13)
        XCTAssertNil(ADTSFraming.header(rawAACFrameSize: oversized, sampleRate: 48_000, channelCount: 2))
    }

    func testHeaderRejectsZeroChannels() {
        XCTAssertNil(ADTSFraming.header(rawAACFrameSize: 100, sampleRate: 48_000, channelCount: 0))
    }

    func testHeaderRejectsExcessiveChannelCount() {
        XCTAssertNil(ADTSFraming.header(rawAACFrameSize: 100, sampleRate: 48_000, channelCount: 8))
    }

    func testHeaderProfileBitsForAACMain() throws {
        let header = try XCTUnwrap(ADTSFraming.header(rawAACFrameSize: 100, sampleRate: 48_000, channelCount: 2, profile: 1))
        let profileBits = (header[2] & 0xC0) >> 6
        XCTAssertEqual(profileBits, 0)
    }

    func testWrapAttachesHeaderAndPayload() throws {
        let packet = EncodedAACPacket(data: Data([0xAA, 0xBB, 0xCC]), frameCount: 1024, presentationTime: 0, sampleRate: 48_000)
        let wrapped = try XCTUnwrap(ADTSFraming.wrap(packet, channelCount: 2))
        XCTAssertEqual(wrapped.count, ADTSFraming.headerByteCount + 3)
        XCTAssertEqual(wrapped.suffix(3), Data([0xAA, 0xBB, 0xCC]))
    }

    func testWrapReturnsNilForUnsupportedSampleRate() {
        let packet = EncodedAACPacket(data: Data([0xAA]), frameCount: 1024, presentationTime: 0, sampleRate: 100)
        XCTAssertNil(ADTSFraming.wrap(packet, channelCount: 2))
    }
}

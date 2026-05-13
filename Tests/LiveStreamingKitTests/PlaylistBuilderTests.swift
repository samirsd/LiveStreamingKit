import XCTest
@testable import LiveStreamingKit

final class PlaylistBuilderTests: XCTestCase {

    func testEmptySegmentListRendersValidEmptyPlaylist() {
        let playlist = PlaylistBuilder(targetDuration: 4, mediaSequence: 0, segments: [], isClosed: false)
        let text = playlist.render()
        XCTAssertTrue(text.contains("#EXTM3U"))
        XCTAssertTrue(text.contains("#EXT-X-TARGETDURATION:4"))
        XCTAssertFalse(text.contains("#EXTINF"))
    }

    func testMediaSequenceWritesNonZeroValue() {
        let playlist = PlaylistBuilder(
            targetDuration: 4,
            mediaSequence: 42,
            segments: [.init(uri: "42.aac", duration: 4)],
            isClosed: false
        )
        XCTAssertTrue(playlist.render().contains("#EXT-X-MEDIA-SEQUENCE:42"))
    }

    func testSegmentDurationsAreFloatRendered() {
        let playlist = PlaylistBuilder(
            targetDuration: 4,
            mediaSequence: 0,
            segments: [.init(uri: "0.aac", duration: 3.123)],
            isClosed: false
        )
        XCTAssertTrue(playlist.render().contains("#EXTINF:3.123,"))
    }

    func testIsClosedAppendsEndlist() {
        let closed = PlaylistBuilder(targetDuration: 4, mediaSequence: 0, segments: [], isClosed: true)
        XCTAssertTrue(closed.render().contains("#EXT-X-ENDLIST"))
        let open = PlaylistBuilder(targetDuration: 4, mediaSequence: 0, segments: [], isClosed: false)
        XCTAssertFalse(open.render().contains("#EXT-X-ENDLIST"))
    }

    func testVersionDefaultsToSix() {
        let playlist = PlaylistBuilder(targetDuration: 4, mediaSequence: 0, segments: [], isClosed: false)
        XCTAssertTrue(playlist.render().contains("#EXT-X-VERSION:6"))
    }

    func testEventPlaylistTypeAlwaysEmitted() {
        let playlist = PlaylistBuilder(targetDuration: 4, mediaSequence: 0, segments: [], isClosed: false)
        XCTAssertTrue(playlist.render().contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
    }

    func testSegmentRefEquality() {
        XCTAssertEqual(
            PlaylistBuilder.SegmentRef(uri: "0.aac", duration: 4.0),
            PlaylistBuilder.SegmentRef(uri: "0.aac", duration: 4.0)
        )
        XCTAssertNotEqual(
            PlaylistBuilder.SegmentRef(uri: "0.aac", duration: 4.0),
            PlaylistBuilder.SegmentRef(uri: "0.aac", duration: 5.0)
        )
    }
}

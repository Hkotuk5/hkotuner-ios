import XCTest
@testable import hkotuner

final class StreamTimingTests: XCTestCase {
    func testPreparedAudioIsReusedOnlyBeforeItsDeadline() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let soon = try XCTUnwrap(URL(string: "https://example.com/audio.m4a?Expires=1750000050"))
        let later = try XCTUnwrap(URL(string: "https://example.com/audio.m4a?expire=1751000000"))
        let invalid = try XCTUnwrap(URL(string: "https://example.com/audio.m4a?expire=unknown"))
        let nearExpiry = try XCTUnwrap(URL(string: "https://example.com/audio.m4a?expire=1750000005"))
        XCTAssertEqual(EmbeddedAudioResolver.reuseDeadline(for: soon, from: now), now.addingTimeInterval(30))
        XCTAssertEqual(EmbeddedAudioResolver.reuseDeadline(for: later, from: now), now.addingTimeInterval(120))
        XCTAssertEqual(EmbeddedAudioResolver.reuseDeadline(for: invalid, from: now), now.addingTimeInterval(120))
        XCTAssertLessThan(EmbeddedAudioResolver.reuseDeadline(for: nearExpiry, from: now), now)
    }

    func testOverstatedDurationUsesTheSongEnd() {
        let timing = StreamTiming(reported: 192, reference: 96)
        XCTAssertEqual(timing.length, 96)
        XCTAssertEqual(timing.end, 96)
    }

    func testBriefDifferencesAndUnknownDurationsDoNotCutPlayback() {
        XCTAssertNil(StreamTiming(reported: 97, reference: 96).end)
        XCTAssertNil(StreamTiming(reported: 2, reference: 1).end)
        XCTAssertEqual(StreamTiming(reported: 96, reference: 192).length, 96)
        XCTAssertEqual(StreamTiming(reported: .infinity, reference: 96).length, 96)
        XCTAssertEqual(StreamTiming(reported: 192, reference: nil).length, 192)
    }

    func testFiniteMediaPlaylistReturnsTheLengthOfItsSegments() throws {
        let base = try XCTUnwrap(URL(string: "https://example.com/hls/master.m3u8"))
        let media = """
        #EXTM3U
        #EXTINF:5.25,
        first.aac
        #EXTINF:3.50,
        last.aac
        #EXT-X-ENDLIST
        """
        XCTAssertEqual(HLSPlaylistTiming.parse(media, base: base), .duration(8.75))
        XCTAssertNil(HLSPlaylistTiming.parse(media.replacingOccurrences(of: "#EXT-X-ENDLIST", with: ""), base: base))
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=48000\ntracks/audio.m3u8"
        let child = try XCTUnwrap(URL(string: "https://example.com/hls/tracks/audio.m3u8"))
        XCTAssertEqual(HLSPlaylistTiming.parse(master, base: base), .variant(child))
    }
}

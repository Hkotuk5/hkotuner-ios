import XCTest
@testable import hkotuner

final class DownloadTests: XCTestCase {
    @MainActor
    func testBatchSkipsAnUncachedYouTubeTrackAfterVerification() async {
        let track = Track.youtube(id: "testBlock42", title: "Test track", artist: "Test artist")
        let downloads = Downloads.shared
        XCTAssertNil(downloads.source(for: track))

        do {
            try await downloads.keep(track, youtubeBlock: .verificationRequired)
            XCTFail("An uncached track should report the YouTube block")
        } catch YouTubeDownloadBlock.verificationRequired {
            XCTAssertFalse(downloads.running.contains(track.id))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

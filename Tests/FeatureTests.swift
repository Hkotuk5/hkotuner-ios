import XCTest
@testable import hkotuner

final class BrowseTests: XCTestCase {
    private func column(_ runs: [[String: Any]]) -> [String: Any] {
        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": runs]]]
    }

    private func link(_ id: String, _ kind: String) -> [String: Any] {
        ["browseEndpoint": [
            "browseId": id,
            "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": kind]],
        ] as [String: Any]]
    }

    func testAlbumRowsTellColumnsApartByLinks() {
        let artistRun: [String: Any] = ["text": "The Weeknd", "navigationEndpoint": link("UClYV6hHlupm_S_ObS1W-DYw", "MUSIC_PAGE_TYPE_ARTIST")]
        let albumRun: [String: Any] = ["text": "After Hours", "navigationEndpoint": link("MPREb_x", "MUSIC_PAGE_TYPE_ALBUM")]
        let fixed: [[String: Any]] = [["musicResponsiveListItemFixedColumnRenderer": ["text": ["runs": [["text": "3:36"]]]]]]
        let row: [String: Any] = [
            "playlistItemData": ["videoId": "RmYCOm4ehKs"],
            "flexColumns": [column([["text": "Save Your Tears"]]), column([artistRun]), column([["text": "3.4B plays"]]), column([albumRun])],
            "fixedColumns": fixed,
        ]
        let t = YTMusic.rowTrack(row)
        XCTAssertEqual(t?.title, "Save Your Tears")
        XCTAssertEqual(t?.artist, "The Weeknd")
        XCTAssertEqual(t?.artistId, "UClYV6hHlupm_S_ObS1W-DYw")
        XCTAssertEqual(t?.album, "After Hours")
        XCTAssertEqual(t?.duration, 216)

        let bare: [String: Any] = [
            "playlistItemData": ["videoId": "bn8gP5N8hqM"],
            "flexColumns": [column([["text": "Cry For Me"]]), column([]), column([["text": "161M plays"]])],
        ]
        let b = YTMusic.rowTrack(bare, artist: (name: "The Weeknd", id: "UC1"), album: "Hurry Up Tomorrow", cover: "https://img")
        XCTAssertEqual(b?.artist, "The Weeknd")
        XCTAssertEqual(b?.artistId, "UC1")
        XCTAssertEqual(b?.album, "Hurry Up Tomorrow")
        XCTAssertEqual(b?.thumbnail, "https://img")
        XCTAssertFalse(YTMusic.validBrowseId("../x"))
        XCTAssertTrue(YTMusic.validBrowseId("MPREb_YWjvGjCFaW6"))
    }

    func testPlaylistSearchRowsAndNextPart() {
        let info: [[String: Any]] = [["text": "Playlist"], ["text": " • "], ["text": "Dima"], ["text": " • "], ["text": "286K views"]]
        let row: [String: Any] = ["musicResponsiveListItemRenderer": [
            "navigationEndpoint": link("VLPLcuffR_HUMsn3lznGDa40t2nyAx5FRill", "MUSIC_PAGE_TYPE_PLAYLIST"),
            "flexColumns": [column([["text": "Кино"]]), column(info)],
        ] as [String: Any]]
        let album: [String: Any] = ["musicResponsiveListItemRenderer": [
            "navigationEndpoint": link("MPREb_album", "MUSIC_PAGE_TYPE_ALBUM"),
            "flexColumns": [column([["text": "An album"]])],
        ] as [String: Any]]
        let cards = YTMusic.listCards(["contents": [row, album]], pageType: YTMusic.playlistPageType)
        XCTAssertEqual(cards.count, 1, "the album is not a playlist")
        XCTAssertEqual(cards.first?.subtitle, "Dima • 286K views")
        XCTAssertEqual(cards.first?.kind, .playlist)

        let command: [String: Any] = ["continuationCommand": ["token": "4qmFsgKHARIk"]]
        let next: [String: Any] = ["contents": [["continuationItemRenderer": ["continuationEndpoint": command]]]]
        XCTAssertEqual(YTMusic.nextPart(next), "4qmFsgKHARIk")
        XCTAssertNil(YTMusic.nextPart(["contents": [Any]()]))
    }

    func testHomeShelves() {
        let two: [String: Any] = ["musicTwoRowItemRenderer": [
            "title": ["runs": [["text": "Mix"]]],
            "subtitle": ["runs": [["text": "Playlist"]]],
            "navigationEndpoint": link("VLRDTMAK5uy_x", "MUSIC_PAGE_TYPE_PLAYLIST"),
        ] as [String: Any]]
        let songSubtitle: [[String: Any]] = [["text": "Song"], ["text": " • "], ["text": "Artist A"]]
        let song: [String: Any] = ["musicTwoRowItemRenderer": [
            "title": ["runs": [["text": "Song A"]]],
            "subtitle": ["runs": songSubtitle],
            "navigationEndpoint": ["watchEndpoint": ["videoId": "dQw4w9WgXcQ"]],
        ] as [String: Any]]
        let header: [String: Any] = ["musicCarouselShelfBasicHeaderRenderer": ["title": ["runs": [["text": "For you"]]]]]
        let shelf: [String: Any] = ["musicCarouselShelfRenderer": ["header": header, "contents": [two, song]] as [String: Any]]
        let shelves = YTMusic.parseHome(["contents": [shelf]])
        XCTAssertEqual(shelves.count, 1)
        XCTAssertEqual(shelves.first?.cards.first?.id, "VLRDTMAK5uy_x")
        XCTAssertEqual(shelves.first?.tracks.first?.artist, "Artist A")
    }

    func testLinks() {
        XCTAssertEqual(YTMusic.playlistId(fromLink: "https://music.youtube.com/playlist?list=PLcuffR_HUMsn3lznGDa40t2nyAx5FRill"), "VLPLcuffR_HUMsn3lznGDa40t2nyAx5FRill")
        XCTAssertEqual(YTMusic.playlistId(fromLink: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=OLAK5uy_abcdefghijk"), "VLOLAK5uy_abcdefghijk")
        XCTAssertNil(YTMusic.playlistId(fromLink: "https://evil.example/playlist?list=PLcuffR_HUMsn3lznGDa40t2nyAx5FRill"))
        let id = "37i9dQZF1DXcBWIGoYBM5M"
        XCTAssertEqual(LinkImport.spotifyLink("https://open.spotify.com/playlist/\(id)?si=abc")?.id, id)
        XCTAssertEqual(LinkImport.spotifyLink("https://open.spotify.com/intl-de/album/\(id)")?.kind, "album")
        XCTAssertNil(LinkImport.spotifyLink("https://open.spotify.com/track/\(id)"))
        XCTAssertNil(LinkImport.spotifyLink("https://evil.example/playlist/\(id)"))
        XCTAssertEqual(LinkImport.kind(of: "spotify:playlist:\(id)"), .spotify(kind: "playlist", id: id))
    }

    func testSpotifyEmbedAndMatching() throws {
        let json = #"{"props":{"pageProps":{"state":{"data":{"entity":{"name":"Road","trackList":[{"title":"Blinding Lights","subtitle":"The Weeknd","duration":200040}]}}}}}}"#
        let html = "<html><script id=\"__NEXT_DATA__\" type=\"application/json\">\(json)</script></html>"
        let (name, wanted) = try LinkImport.parseSpotifyEmbed(html)
        XCTAssertEqual(name, "Road")
        XCTAssertEqual(wanted.first?.artist, "The Weeknd")
        XCTAssertEqual(wanted.first?.duration ?? 0, 200.04, accuracy: 0.01)
        let close = Track.youtube(id: "4NRXx6U8ABQ", title: "Blinding Lights", artist: "The Weeknd", duration: 202)
        let far = Track.youtube(id: "fHI8X4OXluQ", title: "Blinding Lights (Live)", artist: "The Weeknd", duration: 260)
        XCTAssertEqual(LinkImport.bestMatch(wanted[0], [far, close])?.id, close.id)
    }
}

final class ShareTests: XCTestCase {
    /// made in the desktop's format: raw DEFLATE, base64url, a SoundCloud row among YouTube ones
    let desktopLink = "https://hkot.uk/hkotuner/p/#1.q1bKU7JSujDlwr6LDRf2Xdh8YYOSjlKJklV0tFIlkJUSWG5SbhmeHpEcCOT5pZalFim45-flJSq4Z5alKkTmlyqEFgBlgjKTsxUci0tyUoG6jAyNY3WilYqB4olFJZnFJfolRYnJ2UBusDOQcFTSMTQwAMuV5xdlF-tW6OYkFqWn6mUVpCuBNIIsrgyIjCooDy7wzgUqVwrJT08tyQDa7ZZfBHIDho0GprGxtQA"

    func testReadsTheDesktopLink() throws {
        let shared = try ShareCodec.readLink(desktopLink)
        XCTAssertEqual(shared.name, "Дорога")
        XCTAssertEqual(shared.tracks.map(\.videoId), ["dQw4w9WgXcQ", "yPYZpwSpKmA"], "SoundCloud stays on the computer")
        XCTAssertEqual(shared.tracks.first?.duration, 213)
        XCTAssertTrue(ShareCodec.isLink("hkotuner://p/1.q1bK"))
        XCTAssertFalse(ShareCodec.isLink("https://example.com/#2.abc"))
    }

    func testLinkAndFileRoundTrip() throws {
        let tracks = [
            Track.youtube(id: "dQw4w9WgXcQ", title: "Never Gonna Give You Up", artist: "Rick Astley", album: "Whenever", duration: 213),
            Track(id: "local:a.mp3", source: "local", title: "Mine", artist: "", url: "a.mp3"),
        ]
        let back = try ShareCodec.readLink(ShareCodec.makeLink(name: "Тест", tracks: tracks))
        XCTAssertEqual(back.name, "Тест")
        XCTAssertEqual(back.tracks.map(\.id), ["yt:dQw4w9WgXcQ"])
        XCTAssertEqual(ShareCodec.leftBehind(tracks), 1)
        let file = try ShareCodec.makeFile(name: "Тест", tracks: tracks)
        let read = try ShareCodec.readFile(try Data(contentsOf: file))
        XCTAssertEqual(read.tracks.first?.album, "Whenever")
        XCTAssertThrowsError(try ShareCodec.readFile(Data("{}".utf8)))
    }
}

final class EmbeddedAudioResolverTests: XCTestCase {
    func testEmbeddedPythonStartsInsideTheApp() async throws {
        let tracks = try await EmbeddedAudioResolver.searchSoundCloud(" ")
        XCTAssertTrue(tracks.isEmpty)
    }
}

final class AudioStreamTests: XCTestCase {
    func testDirectAudioLinks() throws {
        let address = "https://audio.example.org/Music%20Track.M4A?key=a%2Bb"
        let track = try XCTUnwrap(Track.audioStream(from: " \(address)#player\n"))
        XCTAssertTrue(track.isAudioStream)
        XCTAssertEqual(track.title, "Music Track")
        XCTAssertEqual(track.artist, "audio.example.org")
        XCTAssertEqual(track.audioStreamURL?.absoluteString, address)
        XCTAssertEqual(track.id, Track.audioStream(from: address)?.id)
        let restored = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(track))
        XCTAssertEqual(restored.audioStreamURL, track.audioStreamURL)

        XCTAssertNotNil(Track.audioStream(from: "https://audio.example.org/song.mp3"))
        XCTAssertNotNil(Track.audioStream(from: "https://audio.example.org/live.m3u8"))
    }

    func testDirectAudioLinksRejectWebPagesAndUnsupportedAddresses() {
        XCTAssertNil(Track.audioStream(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(Track.audioStream(from: "https://audio.example.org/page?file=track.mp3"))
        XCTAssertNil(Track.audioStream(from: "https://user:password@audio.example.org/song.mp3"))
        XCTAssertNil(Track.audioStream(from: "http://audio.example.org/song.mp3"))
        XCTAssertNil(Track.audioStream(from: "file:///music/song.mp3"))
    }
}

final class AccountAndLyricsTests: XCTestCase {
    func testSapisidHash() {
        XCTAssertEqual(YTAuth.hash(sapisid: "abcDEF/123", time: 1_700_000_000, origin: "https://music.youtube.com"),
                       "a7ca805bfb7d44212f4eb3f5e51d74ed968bb718")
        XCTAssertEqual(YTAuth.sapisid(from: "A=1; SAPISID=abc; B=2"), "abc")
        XCTAssertEqual(YTAuth.sapisid(from: "__Secure-3PAPISID=xyz"), "xyz")
        XCTAssertNil(YTAuth.sapisid(from: "A=1"))
    }

    func testOnlyYouTubeCookiesAreKept() {
        func cookie(_ name: String, _ domain: String) -> HTTPCookie {
            HTTPCookie(properties: [.name: name, .value: "v-\(name)", .domain: domain, .path: "/"])!
        }
        let header = YTAuth.header(from: [cookie("SAPISID", ".youtube.com"), cookie("SID", ".google.com"), cookie("LOGIN_INFO", ".youtube.com")])
        XCTAssertEqual(header, "SAPISID=v-SAPISID; LOGIN_INFO=v-LOGIN_INFO")
        XCTAssertNil(YTAuth.header(from: [cookie("SID", ".youtube.com")]), "no SAPISID, not signed in")
    }

    func testBotCheckIsRecognised() {
        let status: [String: Any] = ["status": "LOGIN_REQUIRED", "reason": "Sign in to confirm you\u{2019}re not a bot"]
        XCTAssertThrowsError(try StreamResolver.parse(["playabilityStatus": status], userAgent: "ua")) { error in
            XCTAssertTrue(error is BotCheckError)
        }
    }

    func testSyncedLyrics() {
        let lines = LyricsService.parseSynced("[00:05.00]b\n[00:01.00]a\n[00:02.50][01:00.00]twice\nno stamp")
        XCTAssertEqual(lines.map(\.text), ["a", "twice", "b", "twice"])
        XCTAssertEqual(lines.map(\.time), [1, 2.5, 5, 60])
        XCTAssertEqual(LyricsService.current(lines, at: 3), 1)
        XCTAssertNil(LyricsService.current(lines, at: 0.2))
        XCTAssertEqual(LyricsService.cleanTitle("Song (Official Video) [4K]"), "Song")
        XCTAssertEqual(LyricsService.mainArtist("A, B & C"), "A")
    }

    func testLyricSweepSpansFollowingTimestampAndLastLine() {
        let lines = LyricsService.parseSynced("[00:01.00]первая\n[00:01.00]первая\n[00:02.50]последняя")
        XCTAssertEqual(LyricsService.lineSpan(lines[0], in: lines, duration: 7), 1.5)
        XCTAssertEqual(LyricsService.lineSpan(lines[2], in: lines, duration: 7), 4.5)
        XCTAssertEqual(LyricsService.lineSpan(lines[2], in: lines, duration: .infinity), 3)
    }

    func testLyricRowsSharingATimestampAppearInOrder() {
        let parsed = LyricsService.parseSynced("[00:01.00]Первая\n[00:01.00]Вторая\n[00:05.00]Дальше")
        let timeline = LyricsService.displayTimeline(parsed, duration: 9)
        XCTAssertEqual(timeline.map(\.text), ["Первая", "Вторая", "Дальше"])
        XCTAssertEqual(timeline.map(\.time), [1, 3, 5])
        XCTAssertEqual(LyricsService.current(timeline, at: 2.95), 0)
        XCTAssertEqual(LyricsService.current(timeline, at: 3), 1)

        let ending = LyricsService.displayTimeline(Array(parsed.prefix(2)), duration: 7)
        XCTAssertEqual(ending.map(\.time), [1, 4])
    }

    func testVersions() {
        XCTAssertTrue(Updates.newer("0.10.0", than: "0.9.2"))
        XCTAssertFalse(Updates.newer("0.2.0", than: "0.2"))
        XCTAssertFalse(Updates.newer("0.1.9", than: "0.2.0"))
    }

    func testWebPlayerCookiesAndPages() {
        let cookies = WebPlayer.cookies(from: "SAPISID=abc/123; PREF=f6=40000000&hl=ru; broken; =x")
        XCTAssertEqual(cookies.map(\.name), ["SAPISID", "PREF"])
        XCTAssertEqual(cookies[1].value, "f6=40000000&hl=ru")
        XCTAssertEqual(cookies[0].domain, ".youtube.com")
        XCTAssertTrue(cookies[0].isSecure)
        XCTAssertEqual(WebPlayer.pageURL("dQw4w9WgXcQ", site: "music").absoluteString, "https://music.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(WebPlayer.pageURL("dQw4w9WgXcQ", site: "youtube").absoluteString, "https://m.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    func testCardYear() {
        let card = MusicCard(id: "MPREb_x", kind: .album, title: "X", subtitle: "Single • 2025", thumbnail: nil)
        XCTAssertEqual(card.year, 2025)
    }
}

final class StoreTests: XCTestCase {
    @MainActor
    func testFrequentAndForgotten() {
        let stats = StatsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString).json"))
        let t = Track.youtube(id: "dQw4w9WgXcQ", title: "T", artist: "A, B")
        for _ in 0..<3 { stats.countPlay(t) }
        stats.listen(t, seconds: 120)
        XCTAssertEqual(stats.frequent(hidden: []).map(\.id), [t.id])
        XCTAssertTrue(stats.frequent(hidden: [t.id]).isEmpty)
        XCTAssertTrue(stats.forgotten(liked: [t], hidden: []).isEmpty, "heard today is not forgotten")
        let later = Date().addingTimeInterval(40 * 86400)
        XCTAssertEqual(stats.forgotten(liked: [t], hidden: [], now: later).map(\.id), [t.id])
        XCTAssertEqual(stats.topArtists().first?.name, "A")
        XCTAssertEqual(stats.seconds(lastDays: 1), 120)
    }

    @MainActor
    func testAccountImportUpdatesInsteadOfDuplicating() {
        UserDefaults.standard.set(false, forKey: "offlineLikes")
        let store = LibraryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString).json"))
        let a = Track.youtube(id: "dQw4w9WgXcQ", title: "A", artist: "X")
        let b = Track.youtube(id: "yPYZpwSpKmA", title: "B", artist: "X")
        let first = store.importAccount(liked: [a], playlists: [(id: "VLPL1", name: "Road", tracks: [a])])
        XCTAssertEqual(first.liked, 1)
        XCTAssertEqual(first.created, 1)
        let again = store.importAccount(liked: [a, b], playlists: [(id: "VLPL1", name: "Road 2", tracks: [b, a])])
        XCTAssertEqual(again.liked, 1)
        XCTAssertEqual(again.created, 0)
        XCTAssertEqual(again.updated, 1)
        XCTAssertEqual(store.library.playlists.count, 1)
        XCTAssertEqual(store.playlist("yt-VLPL1")?.name, "Road 2")
        XCTAssertEqual(store.playlist("yt-VLPL1")?.tracks.map(\.id), [b.id, a.id])
    }
}

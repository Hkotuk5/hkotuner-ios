import XCTest
@testable import hkotuner

final class ParsingTests: XCTestCase {
    func testGroupsSplitAtDots() {
        XCTAssertEqual(JSONTree.groups(["A", " & ", "B", " • ", "Album", " • ", "3:22"]), ["A & B", "Album", "3:22"])
        XCTAssertEqual(JSONTree.groups([]), [])
    }

    func testDurations() {
        XCTAssertEqual(JSONTree.parseDuration("3:22"), 202)
        XCTAssertEqual(JSONTree.parseDuration("1:02:03"), 3723)
        XCTAssertNil(JSONTree.parseDuration("3"))
        XCTAssertNil(JSONTree.parseDuration("1.2M plays"))
    }

    func testTrackDropsPlaysAndYear() {
        let t = YTMusic.makeTrack(id: "dQw4w9WgXcQ", title: "Song", info: ["Artist", "Album", "2009", "1.2M plays"], length: "3:33", item: [String: Any]())
        XCTAssertEqual(t.artist, "Artist")
        XCTAssertEqual(t.album, "Album")
        XCTAssertEqual(t.duration, 213)
        XCTAssertEqual(t.id, "yt:dQw4w9WgXcQ")
        XCTAssertEqual(t.videoId, "dQw4w9WgXcQ")
    }

    func testSearchRows() {
        let artistLink: [String: Any] = ["browseEndpoint": [
            "browseId": "UCuAXFkgsw1L7xaCfnd5JJOw",
            "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_ARTIST"]],
        ] as [String: Any]]
        let titleRuns: [[String: Any]] = [["text": "Never Gonna Give You Up"]]
        let infoRuns: [[String: Any]] = [
            ["text": "Rick Astley", "navigationEndpoint": artistLink],
            ["text": " • "], ["text": "Whenever You Need Somebody"], ["text": " • "], ["text": "3:34"],
        ]
        func column(_ runs: [[String: Any]]) -> [String: Any] {
            ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": runs]]]
        }
        let thumbs: [[String: Any]] = [
            ["url": "https://lh3.googleusercontent.com/abc=w60-h60-l90-rj"],
            ["url": "https://lh3.googleusercontent.com/abc=w120-h120-l90-rj"],
        ]
        let row: [String: Any] = [
            "playlistItemData": ["videoId": "dQw4w9WgXcQ"],
            "flexColumns": [column(titleRuns), column(infoRuns)],
            "thumbnail": ["musicThumbnailRenderer": ["thumbnail": ["thumbnails": thumbs]]],
        ]
        let root: [String: Any] = ["contents": ["shelf": ["contents": [["musicResponsiveListItemRenderer": row], ["musicResponsiveListItemRenderer": row]]]]]
        let tracks = YTMusic.parseSearch(root, limit: 10)
        XCTAssertEqual(tracks.count, 1, "the same song twice is shown once")
        XCTAssertEqual(tracks.first?.title, "Never Gonna Give You Up")
        XCTAssertEqual(tracks.first?.artist, "Rick Astley")
        XCTAssertEqual(tracks.first?.album, "Whenever You Need Somebody")
        XCTAssertEqual(tracks.first?.duration, 214)
        XCTAssertEqual(tracks.first?.artistId, "UCuAXFkgsw1L7xaCfnd5JJOw")
        XCTAssertEqual(tracks.first?.thumbnail, "https://lh3.googleusercontent.com/abc=w544-h544-l90-rj")
    }

    func testRadioRows() {
        let item: [String: Any] = [
            "videoId": "yPYZpwSpKmA",
            "title": ["runs": [["text": "Together Forever"]]],
            "longBylineText": ["runs": [["text": "Rick Astley"], ["text": " • "], ["text": "Whenever You Need Somebody"], ["text": " • "], ["text": "1987"]]],
            "lengthText": ["runs": [["text": "3:25"]]],
        ]
        let tracks = YTMusic.parseRadio(["panel": ["contents": [["playlistPanelVideoRenderer": item]]]])
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.artist, "Rick Astley")
        XCTAssertEqual(tracks.first?.album, "Whenever You Need Somebody")
        XCTAssertEqual(tracks.first?.duration, 205)
    }

    func testLinks() {
        XCTAssertEqual(YTMusic.videoId(fromLink: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1"), "dQw4w9WgXcQ")
        XCTAssertEqual(YTMusic.videoId(fromLink: "https://music.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(YTMusic.videoId(fromLink: "https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertNil(YTMusic.videoId(fromLink: "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(YTMusic.videoId(fromLink: "rick astley"))
    }

    func testPicksAacAudio() throws {
        let root: [String: Any] = [
            "playabilityStatus": ["status": "OK"],
            "streamingData": [
                "hlsManifestUrl": "https://manifest.googlevideo.com/x/index.m3u8",
                "adaptiveFormats": [
                    ["itag": 251, "mimeType": "audio/webm; codecs=\"opus\"", "bitrate": 136544, "url": "https://rr1.googlevideo.com/opus"],
                    ["itag": 139, "mimeType": "audio/mp4; codecs=\"mp4a.40.5\"", "bitrate": 50152, "url": "https://rr1.googlevideo.com/139"],
                    ["itag": 140, "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"", "bitrate": 130677, "contentLength": "3449447", "url": "https://rr1.googlevideo.com/140"],
                    ["itag": 137, "mimeType": "video/mp4", "bitrate": 4000000, "url": "https://rr1.googlevideo.com/video"],
                ],
            ],
        ]
        let stream = try StreamResolver.parse(root, userAgent: "ua")
        XCTAssertEqual(stream.file?.absoluteString, "https://rr1.googlevideo.com/140")
        XCTAssertEqual(stream.contentLength, 3449447)
        XCTAssertNotNil(stream.hls)
    }

    func testRefusedVideoSaysWhy() {
        let root: [String: Any] = ["playabilityStatus": ["status": "LOGIN_REQUIRED", "reason": "Sign in to confirm your age"]]
        XCTAssertThrowsError(try StreamResolver.parse(root, userAgent: "ua")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Sign in"))
        }
    }

    func testBuiltInConfigIsSane() {
        XCTAssertTrue(ClientConfig.builtIn.isSane)
    }

    func testRepoConfigFileIsSane() throws {
        // the file the app downloads from GitHub must stay readable by the app
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("client-config.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("client-config.json is not reachable from the simulator") }
        let config = try JSONDecoder().decode(ClientConfig.self, from: data)
        XCTAssertTrue(config.isSane)
    }
}

final class LibraryTests: XCTestCase {
    func testDesktopLibraryDecodesWithMissingFields() throws {
        let json = """
        {"liked":[{"id":"yt:dQw4w9WgXcQ","source":"youtube","title":"T","artist":"A","url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ","duration":null,"thumbnail":null}],
         "playlists":[{"id":"p1","name":"Road","tracks":[]}]}
        """
        let lib = try JSONDecoder().decode(Library.self, from: Data(json.utf8))
        XCTAssertEqual(lib.liked.count, 1)
        XCTAssertEqual(lib.playlists.first?.name, "Road")
        XCTAssertTrue(lib.history.isEmpty)
    }

    @MainActor
    private func makeStore() -> LibraryStore {
        UserDefaults.standard.set(false, forKey: "offlineLikes")
        return LibraryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString).json"))
    }

    @MainActor
    func testImportBackupSkipsComputerFiles() throws {
        let store = makeStore()
        let backup = """
        {"kind":"hkotuner-backup","version":1,"createdAt":1,"library":{
          "liked":[
            {"id":"yt:dQw4w9WgXcQ","source":"youtube","title":"T","artist":"A","url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ"},
            {"id":"local:C:/Music/a.mp3","source":"local","title":"L","artist":"","url":"C:/Music/a.mp3"}
          ],
          "playlists":[{"id":"p1","name":"Road","createdAt":5,"tracks":[
            {"id":"yt:yPYZpwSpKmA","source":"youtube","title":"T2","artist":"A","url":"https://www.youtube.com/watch?v=yPYZpwSpKmA"}
          ]}]
        }}
        """
        let added = try store.importDesktop(Data(backup.utf8))
        XCTAssertEqual(added.liked, 1)
        XCTAssertEqual(added.playlists, 1)
        XCTAssertEqual(store.library.liked.map(\.id), ["yt:dQw4w9WgXcQ"])
        let again = try store.importDesktop(Data(backup.utf8))
        XCTAssertEqual(again.liked, 0, "importing twice adds nothing new")
        XCTAssertEqual(again.playlists, 0)
        XCTAssertThrowsError(try store.importDesktop(Data("{}".utf8)))
    }

    @MainActor
    func testLikesPlaylistsAndHistory() {
        let store = makeStore()
        let t = Track.youtube(id: "dQw4w9WgXcQ", title: "T", artist: "A")
        store.toggleLike(t)
        XCTAssertTrue(store.isLiked(t))
        store.toggleDislike(t)
        XCTAssertFalse(store.isLiked(t), "a hidden song is no longer liked")
        let id = store.createPlaylist("  Дорога  ", tracks: [t])
        store.add([t], to: id)
        XCTAssertEqual(store.playlist(id)?.name, "Дорога")
        XCTAssertEqual(store.playlist(id)?.tracks.count, 1)
        for n in 0..<(LibraryStore.historyLimit + 5) {
            store.pushHistory(Track.youtube(id: String(format: "abcdef%05d", n), title: "x", artist: "y"))
        }
        XCTAssertEqual(store.library.history.count, LibraryStore.historyLimit)
    }
}

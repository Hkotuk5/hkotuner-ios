import XCTest
@testable import hkotuner

final class SyncTests: XCTestCase {
    func testOnlineEndpointRequiresAnHTTPSOrigin() throws {
        XCTAssertEqual(try OnlineAccount.endpoint("SYNC.example.com:443/").absoluteString, "https://sync.example.com")
        XCTAssertThrowsError(try OnlineAccount.endpoint("http://sync.example.com"))
        XCTAssertThrowsError(try OnlineAccount.endpoint("https://name:secret@sync.example.com"))
        XCTAssertThrowsError(try OnlineAccount.endpoint("https://sync.example.com/api?account=other"))
    }

    func testDesktopAddressValidatesLocalIPv4AndPort() {
        XCTAssertEqual(DesktopAddress(" 192.168.1.42:52200 ")?.text, "192.168.1.42:52200")
        XCTAssertEqual(DesktopAddress("10.0.0.2")?.text, "10.0.0.2:48627")
        XCTAssertNotNil(DesktopAddress("172.31.1.10:50000")?.endpoint)
        XCTAssertNil(DesktopAddress("172.32.1.10:50000"))
        XCTAssertNil(DesktopAddress("8.8.8.8:50000"))
        XCTAssertNil(DesktopAddress("192.168.1.42:0"))
        XCTAssertNil(DesktopAddress("192.168.1.42:65536"))
        XCTAssertNil(DesktopAddress("192.168.31.999:48627"))
        XCTAssertNil(DesktopAddress("192.168.1.42:48627/path"))
    }

    func testRemoteUnlikeAndLocalPlaylistAdditionBothSurvive() {
        let a = Track.youtube(id: "aaaaaaaaaaa", title: "A", artist: "Artist")
        let b = Track.youtube(id: "bbbbbbbbbbb", title: "B", artist: "Artist")
        let c = Track.youtube(id: "ccccccccccc", title: "C", artist: "Artist")
        var base = SharedLibrary()
        base.liked = [a, b]
        base.playlists = [Playlist(id: "p", name: "Old", tracks: [a], createdAt: 1)]
        var pc = base
        pc.liked = [a]
        pc.playlists[0].name = "Renamed on PC"
        var phone = base
        phone.liked.insert(c, at: 0)
        phone.playlists[0].tracks.append(c)

        let merged = SharedLibrary.merge(base: base, local: pc, incoming: phone)
        XCTAssertEqual(merged.liked, [c, a])
        XCTAssertEqual(merged.playlists[0].name, "Renamed on PC")
        XCTAssertEqual(merged.playlists[0].tracks, [a, c])
    }

    func testDesktopListeningJSONDecodesAndAddsPerDevice() throws {
        let raw = Data("""
            {"years":{"2026":{"seconds":60.0,"plays":1,"tracks":{"yt:aaaaaaaaaaa":
              {"title":"Song","artist":"Band","thumbnail":null,"plays":1,"seconds":60.0}},
              "artists":{"Band":{"plays":1,"seconds":60.0}}}},"genres":{"band":["rock"]}}
            """.utf8)
        let desktop = try JSONDecoder().decode(ListeningSummary.self, from: raw)
        var combined = try XCTUnwrap(desktop.years["2026"])
        var phone = ListeningSummary.Year()
        phone.plays = 1
        phone.seconds = 30
        let song = Track.youtube(id: "aaaaaaaaaaa", title: "Song", artist: "Band")
        phone.tracks[song.id] = ListeningSummary.Song(song)
        phone.tracks[song.id]?.plays = 1
        phone.tracks[song.id]?.seconds = 30
        combined.add(phone)
        XCTAssertEqual(combined.plays, 2)
        XCTAssertEqual(combined.seconds, 90)
        XCTAssertEqual(combined.tracks[song.id]?.plays, 2)
        XCTAssertEqual(desktop.genres["band"], ["rock"])
    }
}

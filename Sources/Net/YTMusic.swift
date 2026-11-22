import Foundation

/// An album, a playlist or an artist as YouTube Music shows it on a card.
struct MusicCard: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case album, playlist, artist }

    /// the browse id: "MPRE…" album, "VL…" playlist, "UC…" artist
    var id: String
    var kind: Kind
    var title: String
    var subtitle: String
    var thumbnail: String?

    var thumbnailURL: URL? { thumbnail.flatMap(URL.init(string:)) }

    /// "Single • 2025" → 2025
    var year: Int? {
        subtitle.components(separatedBy: JSONTree.separator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: JSONTree.isYear)
            .flatMap { Int($0) }
    }
}

struct ArtistPage {
    var id: String
    var name: String
    var thumbnail: String?
    var audience: String?
    var description: String?
    var songs: [Track] = []
    /// the playlist with all of the artist's songs
    var songsId: String?
    var albums: [MusicCard] = []
    var singles: [MusicCard] = []
    var similar: [MusicCard] = []
}

/// an album, or a playlist opened from YouTube Music
struct AlbumPage {
    var id: String
    var title: String
    var artist: String
    var artistId: String?
    var subtitle: String
    var thumbnail: String?
    var tracks: [Track]
    /// the next part of a long playlist
    var more: String?
}

struct HomeShelf: Identifiable {
    var id: String
    var title: String
    var tracks: [Track]
    var cards: [MusicCard]
}

/// YouTube Music's own JSON API: search, radio, artist / album / playlist
/// pages, and — signed in — the listener's likes and playlists.
/// A port of crates/hk-core/src/ytmusic.rs.
enum YTMusic {
    static let api = "https://music.youtube.com/youtubei/v1"
    static let songsFilter = "EgWKAQIIAWoMEA4QChADEAQQCRAF"
    static let artistsFilter = "EgWKAQIgAWoMEA4QChADEAQQCRAF"
    static let albumsFilter = "EgWKAQIYAWoMEA4QChADEAQQCRAF"
    static let featuredPlaylists = "EgeKAQQoADgBagwQDhAKEAMQBBAJEAU%3D"
    static let communityPlaylists = "EgeKAQQoAEABagwQDhAKEAMQBBAJEAU%3D"
    static let artistPageType = "MUSIC_PAGE_TYPE_ARTIST"
    static let albumPageType = "MUSIC_PAGE_TYPE_ALBUM"
    static let playlistPageType = "MUSIC_PAGE_TYPE_PLAYLIST"
    /// a long playlist comes in parts of 100; this many parts at most
    static let maxParts = 20

    /// `auth` sends the signed-in account (YTAuth); without it the request is anonymous
    static func call(_ endpoint: String, body: [String: Any], auth: Bool = false) async throws -> Any {
        var body = body
        body["context"] = ["client": [
            "clientName": "WEB_REMIX",
            "clientVersion": ClientConfigStore.shared.current.musicClientVersion,
            "hl": "en", "gl": "US",
        ] as [String: Any], "user": [String: Any]()]
        var headers = [
            "Origin": YTAuth.origin,
            "Referer": YTAuth.origin + "/",
        ]
        if auth {
            guard let signed = YTAuth.headers() else { throw HKError("Сначала войди в YouTube Music (Настройки → Аккаунт)") }
            headers.merge(signed) { $1 }
        }
        let url = URL(string: "\(api)/\(endpoint)?prettyPrint=false")!
        do {
            return try await HTTP.postJSON(url, body: body, headers: headers, what: "YouTube Music", ownCookies: auth)
        } catch let status as HTTPStatusError where auth && (status.code == 401 || status.code == 403) {
            throw HKError("Вход в YouTube Music устарел — войди заново в настройках")
        }
    }

    // MARK: search

    static func search(_ query: String, limit: Int = 30) async throws -> [Track] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        if let id = videoId(fromLink: q) {
            let tracks = try await radio(videoId: id)
            if let first = tracks.first(where: { $0.videoId == id }) { return [first] }
            return Array(tracks.prefix(1))
        }
        let root = try await call("search", body: ["query": q, "params": songsFilter])
        return parseSearch(root, limit: limit)
    }

    static func searchArtists(_ query: String) async throws -> [MusicCard] {
        let root = try await call("search", body: ["query": query, "params": artistsFilter])
        return listCards(root, pageType: artistPageType)
    }

    static func searchAlbums(_ query: String) async throws -> [MusicCard] {
        let root = try await call("search", body: ["query": query, "params": albumsFilter])
        return listCards(root, pageType: albumPageType)
    }

    static func searchPlaylists(_ query: String, limit: Int = 30) async throws -> [MusicCard] {
        async let featured = try? call("search", body: ["query": query, "params": featuredPlaylists])
        async let community = try? call("search", body: ["query": query, "params": communityPlaylists])
        let answers = await [featured, community].compactMap { $0 }
        guard !answers.isEmpty else { throw HKError("YouTube Music не ответил") }
        var out: [MusicCard] = []
        for card in answers.flatMap({ listCards($0, pageType: playlistPageType) }) where !out.contains(where: { $0.id == card.id }) {
            out.append(card)
            if out.count >= limit { break }
        }
        return out
    }

    /// the artist YouTube Music finds for a name
    static func findArtist(_ name: String) async throws -> MusicCard? {
        let found = try await searchArtists(name)
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return found.first { $0.title.lowercased() == wanted } ?? found.first
    }

    /// the radio YouTube Music starts from one song: ~50 similar tracks, the song first
    static func radio(videoId: String) async throws -> [Track] {
        guard Track.isVideoId(videoId) else { throw HKError("это не трек YouTube") }
        let root = try await call("next", body: [
            "videoId": videoId,
            "playlistId": "RDAMVM\(videoId)",
            "isAudioOnly": true,
            "enablePersistentPlaylistPanel": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ])
        return parseRadio(root)
    }

    // MARK: pages

    static func artist(_ id: String) async throws -> ArtistPage {
        guard validBrowseId(id) else { throw HKError("это не исполнитель") }
        return try parseArtist(try await call("browse", body: ["browseId": id]), id: id)
    }

    static func album(_ id: String) async throws -> AlbumPage {
        guard validBrowseId(id) else { throw HKError("это не альбом") }
        return try parseAlbum(try await call("browse", body: ["browseId": id]), id: id)
    }

    static func playlist(_ id: String, auth: Bool = false) async throws -> AlbumPage {
        guard validBrowseId(id), id.hasPrefix("VL") else { throw HKError("это не плейлист") }
        let root = try await call("browse", body: ["browseId": id], auth: auth)
        let header = JSONTree.collect(root, key: "musicResponsiveHeaderRenderer").first
        let tracks = addRows(root, to: [])
        if tracks.isEmpty && header == nil { throw HKError("плейлист пустой или закрытый") }
        return AlbumPage(
            id: id,
            title: JSONTree.text(JSONTree.pointer(header, "/title")),
            artist: JSONTree.text(JSONTree.pointer(header, "/straplineTextOne")),
            artistId: nil,
            subtitle: "Плейлист",
            thumbnail: JSONTree.bigThumbnail(JSONTree.pointer(header, "/thumbnail")) ?? tracks.first?.thumbnail,
            tracks: tracks,
            more: nextPart(root)
        )
    }

    static func playlistMore(_ token: String, auth: Bool = false) async throws -> (tracks: [Track], more: String?) {
        let root = try await call("browse", body: ["continuation": token], auth: auth)
        return (addRows(root, to: []), nextPart(root))
    }

    /// every song of a playlist, all its parts
    static func playlistSongs(_ id: String, auth: Bool = false) async throws -> [Track] {
        let first = try await playlist(id, auth: auth)
        var out = first.tracks
        var more = first.more
        for _ in 1..<maxParts {
            guard let token = more else { break }
            guard let part = try? await playlistMore(token, auth: auth) else { break }
            let before = out.count
            out = merge(out, part.tracks)
            if out.count == before { break }
            more = part.more
        }
        return out
    }

    /// the start page: shelves of songs and cards; personal when signed in
    static func home(auth: Bool) async throws -> [HomeShelf] {
        parseHome(try await call("browse", body: ["browseId": "FEmusic_home"], auth: auth))
    }

    // MARK: the signed-in account

    /// «Понравившаяся музыка» of the account
    static func likedSongs() async throws -> [Track] {
        try await playlistSongs("VLLM", auth: true)
    }

    /// the playlists in the account's library (made or saved), without the liked songs
    static func libraryPlaylists() async throws -> [MusicCard] {
        var root = try await call("browse", body: ["browseId": "FEmusic_liked_playlists"], auth: true)
        var out: [MusicCard] = []
        for _ in 0..<5 {
            for card in libraryCards(root) where !out.contains(where: { $0.id == card.id }) {
                out.append(card)
            }
            guard let token = nextPart(root) else { break }
            guard let more = try? await call("browse", body: ["continuation": token], auth: true) else { break }
            root = more
        }
        return out
    }

    static func accountName() async throws -> String? {
        let root = try await call("account/account_menu", body: [:], auth: true)
        guard let header = JSONTree.collect(root, key: "activeAccountHeaderRenderer").first else { return nil }
        let name = JSONTree.text(JSONTree.pointer(header, "/accountName"))
        return name.isEmpty ? nil : name
    }

    // MARK: links

    /// a pasted youtube.com / music.youtube.com / youtu.be link to one song
    static func videoId(fromLink text: String) -> String? {
        guard let comps = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = comps.host?.lowercased() else { return nil }
        if host == "youtu.be" {
            let id = String(comps.path.dropFirst())
            return Track.isVideoId(id) ? id : nil
        }
        guard isYouTubeHost(host) else { return nil }
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, Track.isVideoId(v) { return v }
        let parts = comps.path.split(separator: "/")
        if parts.count == 2, parts[0] == "shorts" || parts[0] == "embed", Track.isVideoId(String(parts[1])) {
            return String(parts[1])
        }
        return nil
    }

    /// a link to a playlist or an album on YouTube (Music): its browse id "VL…"
    static func playlistId(fromLink text: String) -> String? {
        guard let comps = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = comps.host?.lowercased(), isYouTubeHost(host),
              let list = comps.queryItems?.first(where: { $0.name == "list" })?.value,
              list.count >= 10, validBrowseId(list),
              !list.hasPrefix("RDAMVM"), list != "LL", list != "WL"
        else { return nil }
        return "VL" + list
    }

    private static func isYouTubeHost(_ host: String) -> Bool {
        host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    // MARK: parsing (kept apart from the network so tests can feed it saved answers)

    static func parseSearch(_ root: Any, limit: Int) -> [Track] {
        var out: [Track] = []
        for item in JSONTree.collect(root, key: "musicResponsiveListItemRenderer") {
            guard let track = listRow(item), !out.contains(where: { $0.id == track.id }) else { continue }
            out.append(track)
            if out.count >= limit { break }
        }
        return out
    }

    /// a search-style row: title, then "Artist • Album • 3:22" in the second column
    static func listRow(_ item: Any) -> Track? {
        guard let id = (JSONTree.string(item, "/playlistItemData/videoId") ?? JSONTree.firstString(item, key: "videoId")),
              Track.isVideoId(id),
              let columns = (item as? [String: Any])?["flexColumns"] as? [Any]
        else { return nil }
        func column(_ i: Int) -> Any? {
            columns.indices.contains(i) ? JSONTree.pointer(columns[i], "/musicResponsiveListItemFlexColumnRenderer/text") : nil
        }
        let title = JSONTree.runs(column(0)).joined()
        guard !title.isEmpty else { return nil }
        var info = JSONTree.groups(JSONTree.runs(column(1)))
        if let kind = info.first, ["Song", "Video", "Episode"].contains(kind) { info.removeFirst() }
        return makeTrack(id: id, title: title, info: info, length: nil, item: item)
    }

    static func parseRadio(_ root: Any) -> [Track] {
        var out: [Track] = []
        for item in JSONTree.collect(root, key: "playlistPanelVideoRenderer") {
            guard let dict = item as? [String: Any],
                  let id = dict["videoId"] as? String, Track.isVideoId(id) else { continue }
            let title = JSONTree.runs(dict["title"]).joined()
            if title.isEmpty || out.contains(where: { $0.videoId == id }) { continue }
            let byline = JSONTree.groups(JSONTree.runs(dict["longBylineText"] ?? dict["shortBylineText"]))
            let length = JSONTree.runs(dict["lengthText"]).joined()
            out.append(makeTrack(id: id, title: title, info: byline, length: length, item: item))
        }
        return out
    }

    /// "Artist • Album • 3:22" (plays, views and the year dropped) into a track
    static func makeTrack(id: String, title: String, info: [String], length: String?, item: Any) -> Track {
        var rest = info
        var duration = length.flatMap(JSONTree.parseDuration)
        var yearSeen = false
        while let last = rest.last {
            if let d = JSONTree.parseDuration(last) {
                duration = duration ?? d
            } else if JSONTree.isYear(last) && !yearSeen && rest.count > 2 {
                yearSeen = true
            } else if !(last.hasSuffix("plays") || last.hasSuffix("views")) {
                break
            }
            rest.removeLast()
        }
        return Track.youtube(
            id: id, title: title,
            artist: rest.first ?? "",
            album: rest.count > 1 ? rest[1] : nil,
            duration: duration,
            thumbnail: JSONTree.bigThumbnail(item),
            artistId: artistLink(item)
        )
    }

    /// a row of an album or playlist page: the columns are told apart by their links
    static func rowTrack(_ item: Any, artist: (name: String, id: String?)? = nil, album: String? = nil, cover: String? = nil) -> Track? {
        guard let dict = item as? [String: Any], let columns = dict["flexColumns"] as? [Any] else { return nil }
        guard let id = JSONTree.string(dict, "/playlistItemData/videoId") ?? JSONTree.firstString(columns, key: "videoId"),
              Track.isVideoId(id) else { return nil }
        func column(_ i: Int) -> Any? {
            columns.indices.contains(i) ? JSONTree.pointer(columns[i], "/musicResponsiveListItemFlexColumnRenderer/text") : nil
        }
        let title = JSONTree.text(column(0))
        guard !title.isEmpty else { return nil }
        var name = ""
        var artistId: String?
        var albumName: String?
        for i in columns.indices.dropFirst() {
            guard let col = column(i) else { continue }
            let words = JSONTree.text(col)
            if words.isEmpty || words.hasSuffix("plays") || words.hasSuffix("views") { continue }
            let runs = ((col as? [String: Any])?["runs"] as? [Any]) ?? []
            let links = runs.compactMap { browseTarget(($0 as? [String: Any])?["navigationEndpoint"]) }
            if links.contains(where: { $0.kind == albumPageType }) {
                albumName = words
            } else if name.isEmpty {
                artistId = links.first(where: { $0.kind == artistPageType })?.id
                name = words
            } else if albumName == nil && i == 3 {
                albumName = words
            }
        }
        let fixed = JSONTree.pointer(dict, "/fixedColumns/0/musicResponsiveListItemFixedColumnRenderer/text")
        if name.isEmpty, let artist {
            name = artist.name
            artistId = artist.id
        }
        return Track.youtube(
            id: id, title: title, artist: name, album: albumName ?? album,
            duration: JSONTree.parseDuration(JSONTree.text(fixed)),
            thumbnail: JSONTree.bigThumbnail(dict["thumbnail"]) ?? cover,
            artistId: artistId
        )
    }

    static func parseArtist(_ root: Any, id: String) throws -> ArtistPage {
        guard let header = JSONTree.pointer(root, "/header/musicImmersiveHeaderRenderer")
                ?? JSONTree.pointer(root, "/header/musicVisualHeaderRenderer")
        else { throw HKError("страница исполнителя пустая") }
        let name = JSONTree.text(JSONTree.pointer(header, "/title"))
        var page = ArtistPage(
            id: id, name: name,
            thumbnail: JSONTree.bigThumbnail(JSONTree.pointer(header, "/thumbnail")),
            audience: nonEmpty(JSONTree.text(JSONTree.pointer(header, "/monthlyListenerCount"))),
            description: nonEmpty(JSONTree.text(JSONTree.pointer(header, "/description")))
        )
        guard let contents = JSONTree.collect(root, key: "sectionListRenderer").first.flatMap({ JSONTree.pointer($0, "/contents") as? [Any] })
        else { return page }
        for section in contents {
            if let shelf = JSONTree.pointer(section, "/musicShelfRenderer") {
                let items = (JSONTree.pointer(shelf, "/contents") as? [Any]) ?? []
                page.songs = items.compactMap { JSONTree.pointer($0, "/musicResponsiveListItemRenderer") }
                    .compactMap { rowTrack($0, artist: (name: name, id: Optional(id))) }
                page.songsId = (browseTarget(JSONTree.pointer(shelf, "/bottomEndpoint"))
                    ?? browseTarget(JSONTree.pointer(shelf, "/title/runs/0/navigationEndpoint")))?.id
            } else if let carousel = JSONTree.pointer(section, "/musicCarouselShelfRenderer") {
                let title = JSONTree.text(JSONTree.pointer(carousel, "/header/musicCarouselShelfBasicHeaderRenderer/title")).lowercased()
                let cards = ((JSONTree.pointer(carousel, "/contents") as? [Any]) ?? []).compactMap { twoRowCard($0) }
                if title.hasPrefix("albums") {
                    page.albums = cards.filter { $0.kind == .album }
                } else if title.hasPrefix("singles") {
                    page.singles = cards.filter { $0.kind == .album }
                } else if title.hasPrefix("fans might also like") || title.hasPrefix("similar") {
                    page.similar = cards.filter { $0.kind == .artist }
                }
            }
        }
        return page
    }

    static func parseAlbum(_ root: Any, id: String) throws -> AlbumPage {
        guard let header = JSONTree.collect(root, key: "musicResponsiveHeaderRenderer").first
        else { throw HKError("страница альбома пустая") }
        let artist = JSONTree.text(JSONTree.pointer(header, "/straplineTextOne"))
        let artistTarget = browseTarget(JSONTree.pointer(header, "/straplineTextOne/runs/0/navigationEndpoint"))
        let artistId = artistTarget?.kind == artistPageType ? artistTarget?.id : nil
        let title = JSONTree.text(JSONTree.pointer(header, "/title"))
        let thumbnail = JSONTree.bigThumbnail(JSONTree.pointer(header, "/thumbnail"))
        var tracks: [Track] = []
        for item in JSONTree.collect(root, key: "musicResponsiveListItemRenderer") {
            guard let t = rowTrack(item, artist: (name: artist, id: artistId), album: title, cover: thumbnail),
                  !tracks.contains(where: { $0.id == t.id }) else { continue }
            tracks.append(t)
        }
        return AlbumPage(id: id, title: title, artist: artist, artistId: artistId,
                         subtitle: JSONTree.text(JSONTree.pointer(header, "/subtitle")),
                         thumbnail: thumbnail, tracks: tracks, more: nil)
    }

    static func parseHome(_ root: Any) -> [HomeShelf] {
        var out: [HomeShelf] = []
        for shelf in JSONTree.collect(root, key: "musicCarouselShelfRenderer") {
            let title = JSONTree.text(JSONTree.pointer(shelf, "/header/musicCarouselShelfBasicHeaderRenderer/title"))
            guard !title.isEmpty, let contents = JSONTree.pointer(shelf, "/contents") as? [Any] else { continue }
            var tracks: [Track] = []
            var cards: [MusicCard] = []
            for item in contents {
                if let row = JSONTree.pointer(item, "/musicResponsiveListItemRenderer") {
                    if let t = listRow(row), !tracks.contains(where: { $0.id == t.id }) { tracks.append(t) }
                } else if let two = JSONTree.pointer(item, "/musicTwoRowItemRenderer") {
                    if let video = JSONTree.string(two, "/navigationEndpoint/watchEndpoint/videoId"), Track.isVideoId(video) {
                        var info = JSONTree.groups(JSONTree.runs(JSONTree.pointer(two, "/subtitle")))
                        if let kind = info.first, ["Song", "Video", "Episode"].contains(kind) { info.removeFirst() }
                        let t = makeTrack(id: video, title: JSONTree.text(JSONTree.pointer(two, "/title")), info: info, length: nil, item: two)
                        if !t.title.isEmpty && !tracks.contains(where: { $0.id == t.id }) { tracks.append(t) }
                    } else if let card = twoRowCard(item) {
                        cards.append(card)
                    }
                }
            }
            if !tracks.isEmpty || !cards.isEmpty {
                out.append(HomeShelf(id: "\(out.count)-\(title)", title: title, tracks: tracks, cards: cards))
            }
        }
        return out
    }

    /// cards of the library page, in its grid or its list view
    static func libraryCards(_ root: Any) -> [MusicCard] {
        let grid = JSONTree.collect(root, key: "musicTwoRowItemRenderer").compactMap { twoRowCard(["musicTwoRowItemRenderer": $0]) }
        let list = listCards(root, pageType: playlistPageType)
        return (grid + list).filter { $0.kind == .playlist && $0.id.hasPrefix("VL") && $0.id != "VLLM" && $0.id != "VLSE" }
    }

    /// rows of a search for artists, albums or playlists
    static func listCards(_ root: Any, pageType: String) -> [MusicCard] {
        var out: [MusicCard] = []
        for item in JSONTree.collect(root, key: "musicResponsiveListItemRenderer") {
            guard let target = browseTarget(JSONTree.pointer(item, "/navigationEndpoint")),
                  target.kind == pageType, validBrowseId(target.id),
                  let kind = cardKind(target.id, target.kind),
                  let columns = JSONTree.pointer(item, "/flexColumns") as? [Any]
            else { continue }
            let title = JSONTree.text(JSONTree.pointer(columns.first, "/musicResponsiveListItemFlexColumnRenderer/text"))
            var info = columns.count > 1 ? JSONTree.groups(JSONTree.runs(JSONTree.pointer(columns[1], "/musicResponsiveListItemFlexColumnRenderer/text"))) : []
            if let first = info.first, ["Artist", "Playlist", "Album"].contains(first) { info.removeFirst() }
            guard !title.isEmpty, !out.contains(where: { $0.id == target.id }) else { continue }
            out.append(MusicCard(id: target.id, kind: kind, title: title, subtitle: info.joined(separator: " • "),
                                 thumbnail: JSONTree.bigThumbnail(JSONTree.pointer(item, "/thumbnail"))))
        }
        return out
    }

    /// `{ "musicTwoRowItemRenderer": … }` linking to an album, a playlist or an artist
    static func twoRowCard(_ item: Any) -> MusicCard? {
        guard let r = JSONTree.pointer(item, "/musicTwoRowItemRenderer"),
              let target = browseTarget(JSONTree.pointer(r, "/navigationEndpoint")),
              validBrowseId(target.id),
              let kind = cardKind(target.id, target.kind)
        else { return nil }
        let title = JSONTree.text(JSONTree.pointer(r, "/title"))
        guard !title.isEmpty else { return nil }
        return MusicCard(id: target.id, kind: kind, title: title,
                         subtitle: JSONTree.text(JSONTree.pointer(r, "/subtitle")),
                         thumbnail: JSONTree.bigThumbnail(JSONTree.pointer(r, "/thumbnailRenderer")))
    }

    private static func cardKind(_ id: String, _ pageType: String) -> MusicCard.Kind? {
        if pageType == albumPageType || id.hasPrefix("MPRE") { return .album }
        if pageType == artistPageType && id.hasPrefix("UC") { return .artist }
        if pageType == playlistPageType && id.hasPrefix("VL") { return .playlist }
        return nil
    }

    static func browseTarget(_ value: Any?) -> (id: String, kind: String)? {
        guard let endpoint = JSONTree.pointer(value, "/browseEndpoint"),
              let id = JSONTree.string(endpoint, "/browseId"),
              let kind = JSONTree.string(endpoint, "/browseEndpointContextSupportedConfigs/browseEndpointContextMusicConfig/pageType")
        else { return nil }
        return (id, kind)
    }

    /// a YouTube Music page id this app may ask for
    static func validBrowseId(_ id: String) -> Bool {
        (2...128).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func nextPart(_ root: Any) -> String? {
        for command in JSONTree.collect(root, key: "continuationCommand") {
            if let token = JSONTree.string(command, "/token"), !token.isEmpty, token.count < 4096 { return token }
        }
        for data in JSONTree.collect(root, key: "nextContinuationData") {
            if let token = JSONTree.string(data, "/continuation"), !token.isEmpty, token.count < 4096 { return token }
        }
        return nil
    }

    private static func addRows(_ root: Any, to tracks: [Track]) -> [Track] {
        merge(tracks, JSONTree.collect(root, key: "musicResponsiveListItemRenderer").compactMap { rowTrack($0) })
    }

    private static func merge(_ a: [Track], _ b: [Track]) -> [Track] {
        var seen = Set(a.map(\.id))
        var out = a
        for t in b where !seen.contains(t.id) {
            seen.insert(t.id)
            out.append(t)
        }
        return out
    }

    private static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

    /// the first artist page linked anywhere in a row
    static func artistLink(_ item: Any) -> String? {
        for link in JSONTree.collect(item, key: "navigationEndpoint") {
            if let target = browseTarget(link), target.kind == artistPageType, target.id.hasPrefix("UC") { return target.id }
        }
        return nil
    }
}

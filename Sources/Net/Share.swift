import Compression
import Foundation

/// A playlist that came from somewhere: a link, a file, Spotify, YouTube.
struct SharedPlaylist: Identifiable {
    let id = UUID()
    var name: String
    var tracks: [Track]
    /// "Artist — Title" of the songs that were not found
    var missing: [String] = []
}

/// Playlists as links and files, in the desktop app's format
/// (crates/hk-app/src/share.rs), so they open in either app. Only YouTube
/// songs travel from the phone; SoundCloud songs from the computer are read
/// but play only there.
enum ShareCodec {
    static let base = "https://hkot.uk/hkotuner/p/"
    static let fileExtension = "hkplaylist"
    static let fileFormat = "hkotuner-playlist"
    static let maxTracks = 2000
    static let maxUnpacked = 4 << 20

    // MARK: going out

    static func makeLink(name: String, tracks: [Track]) -> String {
        let rows: [[Any]] = tracks.compactMap { t in
            guard let id = t.videoId else { return nil }
            return ["y", id, t.title, t.artist, number(t.duration ?? 0)]
        }
        let object: [String: Any] = ["n": name, "t": rows]
        guard let json = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let packed = deflate(json) else { return base }
        return base + "#1." + base64url(packed)
    }

    static func makeFile(name: String, tracks: [Track]) throws -> URL {
        let rows: [[String: Any]] = tracks.compactMap { t in
            guard let id = t.videoId else { return nil }
            var row: [String: Any] = ["source": "youtube", "key": id, "title": t.title, "artist": t.artist]
            if let album = t.album { row["album"] = album }
            if let d = t.duration { row["duration"] = number(d) }
            return row
        }
        let object: [String: Any] = ["format": fileFormat, "version": 1, "name": name, "tracks": rows]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
        let clean = name.map { "/\\:?*\"<>|".contains($0) ? " " : $0 }
        let fileName = String(String(clean).trimmingCharacters(in: .whitespaces).prefix(80))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(fileName.isEmpty ? "playlist" : fileName).\(fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// how many songs cannot travel (own files)
    static func leftBehind(_ tracks: [Track]) -> Int { tracks.filter { $0.videoId == nil }.count }

    // MARK: coming in

    static func isLink(_ text: String) -> Bool { linkData(text) != nil }

    static func readLink(_ text: String) throws -> SharedPlaylist {
        guard let data = linkData(text), let packed = unbase64url(data) else { throw HKError("Это не ссылка на плейлист") }
        guard let json = inflate(packed) else { throw HKError("Ссылка повреждена") }
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw HKError("Ссылка повреждена") }
        let rows = (root["t"] as? [Any]) ?? []
        let tracks = rows.compactMap { row -> Track? in
            guard let r = row as? [Any], r.count >= 4 else { return nil }
            return entry(kind: r[0] as? String, key: r[1], title: r[2], artist: r[3], album: nil, duration: r.count > 4 ? r[4] : nil)
        }
        return try shared(name: root["n"], tracks: tracks)
    }

    static func readFile(_ data: Data) throws -> SharedPlaylist {
        guard data.count < 5 << 20,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["format"] as? String == fileFormat,
              let rows = root["tracks"] as? [Any]
        else { throw HKError("Это не файл плейлиста hkotuner") }
        let tracks = rows.compactMap { row -> Track? in
            guard let r = row as? [String: Any] else { return nil }
            let kind: String? = (r["source"] as? String) == "youtube" ? "y" : nil
            return entry(kind: kind, key: r["key"], title: r["title"], artist: r["artist"], album: r["album"], duration: r["duration"])
        }
        return try shared(name: root["name"], tracks: tracks)
    }

    private static func entry(kind: String?, key: Any?, title: Any?, artist: Any?, album: Any?, duration: Any?) -> Track? {
        guard kind == "y", let id = key as? String, Track.isVideoId(id) else { return nil }
        let name = text(title)
        guard !name.isEmpty else { return nil }
        let length = (duration as? Double).flatMap { $0.isFinite && $0 > 0 && $0 < 86400 ? $0 : nil }
        let albumName = text(album)
        return Track.youtube(id: id, title: name, artist: text(artist), album: albumName.isEmpty ? nil : albumName, duration: length)
    }

    private static func shared(name: Any?, tracks: [Track]) throws -> SharedPlaylist {
        var seen = Set<String>()
        let unique = tracks.prefix(maxTracks).filter { seen.insert($0.id).inserted }
        guard !unique.isEmpty else { throw HKError("В плейлисте нет песен, которые играют на iPhone") }
        let title = text(name)
        return SharedPlaylist(name: title.isEmpty ? "Плейлист" : String(title.prefix(100)), tracks: Array(unique))
    }

    private static func text(_ value: Any?) -> String {
        guard let s = value as? String else { return "" }
        return String(s.filter { !$0.isNewline }.trimmingCharacters(in: .whitespaces).prefix(200))
    }

    private static func number(_ n: Double) -> Any {
        n.rounded() == n && abs(n) < 1e9 ? Int(n) as Any : n as Any
    }

    /// the squeezed list after `#1.`, or after `hkotuner://p/1.` from the share page
    static func linkData(_ text: String) -> String? {
        let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var data: Substring?
        if let r = link.range(of: "#1.") {
            data = link[r.upperBound...]
        } else if let r = link.range(of: "hkotuner://p/1.") {
            data = link[r.upperBound...]
        }
        guard let found = data, !found.isEmpty, found.count < 1_000_000,
              found.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        return String(found)
    }

    // MARK: raw DEFLATE and base64url (Apple's "zlib" is raw DEFLATE, as the desktop writes)

    static func deflate(_ data: Data) -> Data? {
        try? (data as NSData).compressed(using: .zlib) as Data
    }

    static func inflate(_ data: Data) -> Data? {
        let capacity = maxUnpacked + 1
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, capacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < capacity else { return nil }
        return out.prefix(written)
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func unbase64url(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

/// Playlists from other services, matched song by song to YouTube Music.
enum LinkImport {
    /// what a pasted link is
    enum Kind: Equatable {
        case shared
        case youtubePlaylist(String)
        case spotify(kind: String, id: String)
    }

    static func kind(of text: String) -> Kind? {
        if ShareCodec.isLink(text) { return .shared }
        if let id = YTMusic.playlistId(fromLink: text) { return .youtubePlaylist(id) }
        if let s = spotifyLink(text) { return .spotify(kind: s.kind, id: s.id) }
        return nil
    }

    static func load(_ text: String, progress: @escaping @MainActor (Int, Int) -> Void) async throws -> SharedPlaylist {
        switch kind(of: text) {
        case .shared:
            return try ShareCodec.readLink(text)
        case .youtubePlaylist(let id):
            let page = try await YTMusic.playlist(id)
            var tracks = page.tracks
            var more = page.more
            for _ in 1..<YTMusic.maxParts {
                guard let token = more, let part = try? await YTMusic.playlistMore(token) else { break }
                let known = Set(tracks.map(\.id))
                let fresh = part.tracks.filter { !known.contains($0.id) }
                if fresh.isEmpty { break }
                tracks += fresh
                more = part.more
                await progress(tracks.count, 0)
            }
            guard !tracks.isEmpty else { throw HKError("Плейлист пустой или закрытый") }
            return SharedPlaylist(name: page.title.isEmpty ? "Плейлист YouTube" : page.title, tracks: tracks)
        case .spotify(let kind, let id):
            return try await spotify(kind: kind, id: id, progress: progress)
        case nil:
            throw HKError("Не понимаю эту ссылку. Подходят ссылки на плейлисты YouTube, Spotify и hkotuner.")
        }
    }

    // MARK: Spotify — its audio is DRM-protected, so only the list comes over

    struct Wanted: Equatable {
        var title: String
        var artist: String
        var duration: Double?
    }

    static func spotifyLink(_ raw: String) -> (kind: String, id: String)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid: (String) -> Bool = { id in (16...32).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
        let kinds = ["playlist", "album"]
        if text.hasPrefix("spotify:") {
            let parts = text.split(separator: ":").map(String.init)
            guard parts.count >= 3, kinds.contains(parts[1]), valid(parts[2]) else { return nil }
            return (parts[1], parts[2])
        }
        guard let url = URL(string: text), url.host?.lowercased() == "open.spotify.com" else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        guard let at = segments.firstIndex(where: kinds.contains), at + 1 < segments.count, valid(segments[at + 1]) else { return nil }
        return (segments[at], segments[at + 1])
    }

    /// the track list inside the public embed page's `__NEXT_DATA__` JSON
    static func parseSpotifyEmbed(_ html: String) throws -> (name: String, tracks: [Wanted]) {
        let marker = "<script id=\"__NEXT_DATA__\" type=\"application/json\">"
        guard let start = html.range(of: marker),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let root = try? JSONSerialization.jsonObject(with: Data(html[start.upperBound..<end.lowerBound].utf8))
        else { throw HKError("Spotify не показал этот плейлист") }
        guard let entity = JSONTree.pointer(root, "/props/pageProps/state/data/entity") as? [String: Any]
        else { throw HKError("Плейлист закрытый или его нет") }
        let name = (entity["name"] as? String) ?? (entity["title"] as? String) ?? "Spotify"
        let tracks = ((entity["trackList"] as? [Any]) ?? []).compactMap { item -> Wanted? in
            guard let t = item as? [String: Any],
                  let title = (t["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
            let artist = ((t["subtitle"] as? String) ?? "").replacingOccurrences(of: "\u{a0}", with: " ")
            return Wanted(title: title, artist: artist, duration: (t["duration"] as? Double).map { $0 / 1000 })
        }
        guard !tracks.isEmpty else { throw HKError("Плейлист пустой или закрытый") }
        return (name, tracks)
    }

    /// the search result whose length is closest to the wanted song
    static func bestMatch(_ wanted: Wanted, _ found: [Track]) -> Track? {
        guard let duration = wanted.duration else { return found.first }
        var best: (score: Double, track: Track)?
        for (rank, t) in found.enumerated() {
            let off = t.duration.map { abs($0 - duration) } ?? 30
            guard off <= 12 else { continue }
            let score = off + Double(rank) * 1.5
            if best == nil || score < best!.score { best = (score, t) }
        }
        return best?.track
    }

    private static func match(_ want: Wanted) async -> Track? {
        let query = "\(want.artist) \(want.title)".trimmingCharacters(in: .whitespaces)
        let found = (try? await YTMusic.search(query, limit: 5)) ?? []
        return bestMatch(want, found)
    }

    private static func spotify(kind: String, id: String, progress: @escaping @MainActor (Int, Int) -> Void) async throws -> SharedPlaylist {
        let data = try await HTTP.get(URL(string: "https://open.spotify.com/embed/\(kind)/\(id)")!, what: "Spotify")
        let (name, wanted) = try parseSpotifyEmbed(String(decoding: data, as: UTF8.self))
        var matched = [Track?](repeating: nil, count: wanted.count)
        var done = 0
        await progress(0, wanted.count)
        try await withThrowingTaskGroup(of: (Int, Track?).self) { group in
            var next = 0
            while next < min(4, wanted.count) {
                let i = next
                let want = wanted[i]
                next += 1
                group.addTask { (i, await LinkImport.match(want)) }
            }
            while let (i, track) = try await group.next() {
                matched[i] = track
                done += 1
                await progress(done, wanted.count)
                if next < wanted.count {
                    let j = next
                    let want = wanted[j]
                    next += 1
                    group.addTask { (j, await LinkImport.match(want)) }
                }
            }
        }
        var tracks: [Track] = []
        var missing: [String] = []
        for (i, track) in matched.enumerated() {
            if let track, !tracks.contains(where: { $0.id == track.id }) {
                tracks.append(track)
            } else if track == nil {
                missing.append("\(wanted[i].artist) — \(wanted[i].title)")
            }
        }
        guard !tracks.isEmpty else { throw HKError("Ни одна песня не нашлась в YouTube Music") }
        return SharedPlaylist(name: name, tracks: tracks, missing: missing)
    }
}

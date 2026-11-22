import Foundation

/// YouTube Music's own JSON API: song search and the radio behind
/// "Моя волна" / similar songs. A port of crates/hk-core/src/ytmusic.rs.
enum YTMusic {
    static let api = "https://music.youtube.com/youtubei/v1"
    /// the "Songs" filter of the search page
    static let songsFilter = "EgWKAQIIAWoMEA4QChADEAQQCRAF"

    static func call(_ endpoint: String, body: [String: Any]) async throws -> Any {
        var body = body
        body["context"] = ["client": [
            "clientName": "WEB_REMIX",
            "clientVersion": ClientConfigStore.shared.current.musicClientVersion,
            "hl": "en", "gl": "US",
        ]]
        let url = URL(string: "\(api)/\(endpoint)?prettyPrint=false")!
        return try await HTTP.postJSON(url, body: body, headers: [
            "Origin": "https://music.youtube.com",
            "Referer": "https://music.youtube.com/",
        ], what: "YouTube Music")
    }

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

    /// a pasted youtube.com / music.youtube.com / youtu.be link to one song
    static func videoId(fromLink text: String) -> String? {
        guard let comps = URLComponents(string: text), let host = comps.host?.lowercased() else { return nil }
        if host == "youtu.be" {
            let id = String(comps.path.dropFirst())
            return Track.isVideoId(id) ? id : nil
        }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, Track.isVideoId(v) { return v }
        let parts = comps.path.split(separator: "/")
        if parts.count == 2, parts[0] == "shorts" || parts[0] == "embed", Track.isVideoId(String(parts[1])) {
            return String(parts[1])
        }
        return nil
    }

    // MARK: parsing (kept apart from the network so tests can feed it saved answers)

    static func parseSearch(_ root: Any, limit: Int) -> [Track] {
        var out: [Track] = []
        for item in JSONTree.collect(root, key: "musicResponsiveListItemRenderer") {
            guard let id = (JSONTree.string(item, "/playlistItemData/videoId") ?? JSONTree.firstString(item, key: "videoId")),
                  Track.isVideoId(id),
                  let columns = (item as? [String: Any])?["flexColumns"] as? [Any]
            else { continue }
            func column(_ i: Int) -> Any? {
                columns.indices.contains(i) ? JSONTree.pointer(columns[i], "/musicResponsiveListItemFlexColumnRenderer/text") : nil
            }
            let title = JSONTree.runs(column(0)).joined()
            if title.isEmpty || out.contains(where: { $0.videoId == id }) { continue }
            out.append(makeTrack(id: id, title: title, info: JSONTree.groups(JSONTree.runs(column(1))), length: nil, item: item))
            if out.count >= limit { break }
        }
        return out
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

    /// the first artist page linked anywhere in a row
    static func artistLink(_ item: Any) -> String? {
        for link in JSONTree.collect(item, key: "navigationEndpoint") {
            guard let browse = (link as? [String: Any])?["browseEndpoint"] as? [String: Any],
                  let id = browse["browseId"] as? String,
                  let kind = JSONTree.string(browse, "/browseEndpointContextSupportedConfigs/browseEndpointContextMusicConfig/pageType")
            else { continue }
            if kind == "MUSIC_PAGE_TYPE_ARTIST" && id.hasPrefix("UC") { return id }
        }
        return nil
    }
}

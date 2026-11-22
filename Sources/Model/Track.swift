import CryptoKit
import Foundation

/// One song, in the same JSON shape as the desktop app's `Track`
/// (crates/hk-core/src/catalog.rs), so libraries move between them.
struct Track: Codable, Hashable, Identifiable {
    /// A stable identifier for a catalog track, local file or direct audio link.
    var id: String
    var source: String
    var title: String
    var artist: String
    var album: String?
    var duration: Double?
    var thumbnail: String?
    /// A catalog page, a local file name or a direct audio URL.
    var url: String
    var artistId: String?
    var composer: String?

    var isYouTube: Bool { source == "youtube" && videoId != nil }
    var isLocal: Bool { source == "local" }
    var isAudioStream: Bool { source == "stream" }
    var audioStreamURL: URL? { isAudioStream ? Self.directAudioURL(url) : nil }

    /// the 11 characters after "yt:"
    var videoId: String? {
        guard id.hasPrefix("yt:") else { return nil }
        let rest = String(id.dropFirst(3))
        return Track.isVideoId(rest) ? rest : nil
    }

    var thumbnailURL: URL? { thumbnail.flatMap(URL.init(string:)) }

    var durationText: String {
        guard let d = duration, d > 0 else { return "" }
        return Track.clock(d)
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds.rounded() : 0))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func isVideoId(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func youtube(id: String, title: String, artist: String, album: String? = nil,
                        duration: Double? = nil, thumbnail: String? = nil, artistId: String? = nil) -> Track {
        Track(id: "yt:\(id)", source: "youtube", title: title, artist: artist, album: album,
              duration: duration,
              thumbnail: thumbnail ?? "https://i.ytimg.com/vi/\(id)/hqdefault.jpg",
              url: "https://www.youtube.com/watch?v=\(id)", artistId: artistId, composer: nil)
    }

    static func audioStream(from text: String) -> Track? {
        guard let url = directAudioURL(text), let host = url.host else { return nil }
        let address = url.absoluteString
        let digest = SHA256.hash(data: Data(address.utf8))
        let id = "stream:" + Data(digest).base64EncodedString()
        let title = url.deletingPathExtension().lastPathComponent
        return Track(id: id, source: "stream", title: title.isEmpty ? host : title, artist: host,
                     album: nil, duration: nil, thumbnail: nil,
                     url: address, artistId: nil, composer: nil)
    }

    private static func directAudioURL(_ text: String) -> URL? {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: address), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        parts.fragment = nil
        guard let url = parts.url, ["mp3", "m4a", "m3u8"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }
}

struct Playlist: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var tracks: [Track]
    var createdAt: UInt64
    var cover: String?

    init(id: String, name: String, tracks: [Track] = [], createdAt: UInt64, cover: String? = nil) {
        self.id = id; self.name = name; self.tracks = tracks; self.createdAt = createdAt; self.cover = cover
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        createdAt = try c.decodeIfPresent(UInt64.self, forKey: .createdAt) ?? 0
        cover = try c.decodeIfPresent(String.self, forKey: .cover)
    }
}

struct FollowedArtist: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var thumbnail: String?
}

/// Everything the listener made; the desktop `Library` (crates/hk-core/src/library.rs)
/// with every field optional when read, so either app's file opens in the other.
struct Library: Codable {
    var liked: [Track] = []
    var playlists: [Playlist] = []
    var history: [Track] = []
    var local: [Track] = []
    var artists: [FollowedArtist] = []
    var disliked: [Track] = []
    var tagsVersion: UInt32 = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        liked = try c.decodeIfPresent([Track].self, forKey: .liked) ?? []
        playlists = try c.decodeIfPresent([Playlist].self, forKey: .playlists) ?? []
        history = try c.decodeIfPresent([Track].self, forKey: .history) ?? []
        local = try c.decodeIfPresent([Track].self, forKey: .local) ?? []
        artists = try c.decodeIfPresent([FollowedArtist].self, forKey: .artists) ?? []
        disliked = try c.decodeIfPresent([Track].self, forKey: .disliked) ?? []
        tagsVersion = try c.decodeIfPresent(UInt32.self, forKey: .tagsVersion) ?? 0
    }
}

/// the desktop app's backup file ("hkotuner-backup"), read for its library only
struct DesktopBackup: Decodable {
    var kind: String
    var library: Library
}

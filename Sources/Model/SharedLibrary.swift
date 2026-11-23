import Foundation

/// Catalog entries travel between devices. File paths and covers chosen on one device stay there.
struct SharedLibrary: Codable, Equatable {
    var liked: [Track] = []
    var playlists: [Playlist] = []

    init() {}

    init(_ library: Library) {
        liked = library.liked.filter(Self.portable)
        playlists = library.playlists.map { playlist in
            var copy = playlist
            copy.tracks = playlist.tracks.filter(Self.portable)
            copy.cover = nil
            return copy
        }
    }

    func apply(to library: inout Library) {
        library.liked = Self.includeLocal(liked, from: library.liked)
        let old = Self.entries(library.playlists)
        library.playlists = playlists.map { playlist in
            var copy = playlist
            if let existing = old[playlist.id] {
                copy.tracks = Self.includeLocal(playlist.tracks, from: existing.tracks)
                copy.cover = existing.cover
            }
            return copy
        }
        let likes = Set(library.liked.map(\.id))
        library.disliked.removeAll { likes.contains($0.id) }
    }

    static func merge(base: Self, local: Self, incoming: Self) -> Self {
        var result = Self()
        result.liked = mergeRows(base.liked, local.liked, incoming.liked, merging: prefer)
        result.playlists = mergeRows(base.playlists, local.playlists, incoming.playlists, merging: mergePlaylist)
        return result
    }

    private static func portable(_ track: Track) -> Bool { track.isYouTube || track.isSoundCloud }

    private static func includeLocal(_ shared: [Track], from old: [Track]) -> [Track] {
        var tracks = shared
        for (index, track) in old.enumerated() where !portable(track) {
            tracks.insert(track, at: min(index, tracks.count))
        }
        return tracks
    }

    private static func entries<Row: Identifiable>(_ rows: [Row]) -> [Row.ID: Row] {
        Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func prefer<Row: Equatable>(_ base: Row?, _ local: Row?, _ incoming: Row?) -> Row? {
        incoming == base ? local : incoming
    }

    private static func mergePlaylist(_ base: Playlist?, _ local: Playlist?, _ incoming: Playlist?) -> Playlist? {
        guard var merged = local, let incoming else { return prefer(base, local, incoming) }
        if base?.name != incoming.name { merged.name = incoming.name }
        if merged.createdAt == 0 { merged.createdAt = incoming.createdAt }
        merged.tracks = mergeRows(base?.tracks ?? [], merged.tracks, incoming.tracks, merging: prefer)
        return merged
    }

    private static func mergeRows<Row: Identifiable>(
        _ base: [Row], _ local: [Row], _ incoming: [Row],
        merging: (Row?, Row?, Row?) -> Row?
    ) -> [Row] {
        let baseMap = entries(base)
        let localMap = entries(local)
        let incomingMap = entries(incoming)
        let retained = incoming.map(\.id).filter { baseMap[$0] != nil }
        let oldOrder = base.map(\.id).filter { incomingMap[$0] != nil }
        let useIncoming = !base.isEmpty && (retained.count != incoming.count || retained != oldOrder)
        var seen = Set<Row.ID>()
        return (useIncoming ? incoming + local : local + incoming).map(\.id).compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return merging(baseMap[id], localMap[id], incomingMap[id])
        }
    }
}

struct ListeningSummary: Codable, Equatable {
    struct Count: Codable, Equatable {
        var plays: UInt64 = 0
        var seconds: Double = 0

        mutating func add(_ other: Self) {
            plays += other.plays
            seconds += other.seconds
        }
    }

    struct Song: Codable, Equatable {
        var title: String
        var artist: String
        var thumbnail: String?
        var plays: UInt64 = 0
        var seconds: Double = 0
        var last: UInt64?

        init(_ track: Track) {
            title = track.title
            artist = track.artist
            thumbnail = track.thumbnail
        }

        mutating func add(_ other: Self) {
            plays += other.plays
            seconds += other.seconds
        }
    }

    struct Year: Codable, Equatable {
        var seconds: Double = 0
        var plays: UInt64 = 0
        var tracks: [String: Song] = [:]
        var artists: [String: Count] = [:]

        mutating func add(_ other: Self) {
            plays += other.plays
            seconds += other.seconds
            for (id, song) in other.tracks {
                if tracks[id] == nil { tracks[id] = song }
                else { tracks[id]?.add(song) }
            }
            for (artist, count) in other.artists { artists[artist, default: Count()].add(count) }
        }
    }

    var years: [String: Year] = [:]
    var genres: [String: [String]] = [:]
}

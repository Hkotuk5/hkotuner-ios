import Foundation

struct Lyrics: Equatable {
    var synced: String?
    var plain: String?
}

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
}

/// Lyrics from LRCLIB (lrclib.net), a free open lyrics database: synced
/// (`[mm:ss.xx] line`) when it has them, plain text otherwise. The same lookup
/// as crates/hk-core/src/lyrics.rs.
actor LyricsService {
    static let shared = LyricsService()
    static let api = "https://lrclib.net/api"

    private var found: [String: Lyrics?] = [:]

    func find(_ track: Track) async -> Lyrics? {
        if let hit = found[track.id] { return hit }
        let title = Self.cleanTitle(track.title)
        let artist = Self.mainArtist(track.artist)
        var query = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if let d = track.duration { query.append(URLQueryItem(name: "duration", value: String(Int(d.rounded())))) }
        // an exact match first, then the closest search result
        var lyrics = (await Self.get("get", query)).flatMap(Self.record)
        if lyrics == nil, let list = await Self.get("search", Array(query.prefix(2))) as? [Any] {
            let close = list.filter { item in
                guard let a = track.duration, let b = (item as? [String: Any])?["duration"] as? Double else { return true }
                return abs(a - b) <= 4
            }
            let all = close.compactMap(Self.record)
            lyrics = all.first(where: { $0.synced != nil }) ?? all.first
        }
        if found.count > 200 { found.removeAll() }
        found[track.id] = lyrics
        return lyrics
    }

    private static func get(_ path: String, _ query: [URLQueryItem]) async -> Any? {
        var comps = URLComponents(string: "\(api)/\(path)")!
        comps.queryItems = query
        guard let url = comps.url else { return nil }
        return try? await HTTP.getJSON(url, headers: ["User-Agent": HTTP.appAgent], what: "LRCLIB", timeout: 12)
    }

    static func record(_ value: Any) -> Lyrics? {
        guard let dict = value as? [String: Any] else { return nil }
        func text(_ key: String) -> String? {
            guard let s = (dict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        let lyrics = Lyrics(synced: text("syncedLyrics"), plain: text("plainLyrics"))
        return lyrics.synced == nil && lyrics.plain == nil ? nil : lyrics
    }

    /// "Song (Official Video) [4K]" → "Song": upload decorations confuse the lookup
    static func cleanTitle(_ title: String) -> String {
        var out = ""
        var depth = 0
        for c in title {
            switch c {
            case "(", "[": depth += 1
            case ")", "]": depth = max(0, depth - 1)
            default: if depth == 0 { out.append(c) }
            }
        }
        let clean = out.trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? title.trimmingCharacters(in: .whitespaces) : clean
    }

    /// "A, B & C" → "A": the database lists the main artist
    static func mainArtist(_ artist: String) -> String {
        String(artist.split(whereSeparator: { $0 == "," || $0 == "&" }).first ?? Substring(artist))
            .trimmingCharacters(in: .whitespaces)
    }

    /// "[01:02.50] words" lines in time order; a line may carry several stamps
    static func parseSynced(_ text: String) -> [LyricLine] {
        var timed: [(Double, String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw).drop(while: { $0 == " " })
            var stamps: [Double] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let stamp = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                if let t = seconds(stamp) { stamps.append(t) }
            }
            let words = rest.trimmingCharacters(in: .whitespaces)
            for t in stamps { timed.append((t, words)) }
        }
        return timed.sorted { $0.0 < $1.0 }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    /// "01:02.50" → 62.5
    private static func seconds(_ stamp: Substring) -> Double? {
        let parts = stamp.split(separator: ":")
        guard parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
        return m * 60 + s
    }

    /// the line being sung at `time`
    static func current(_ lines: [LyricLine], at time: Double) -> Int? {
        var found: Int?
        for line in lines {
            if line.time <= time + 0.2 { found = line.id } else { break }
        }
        return found
    }
}

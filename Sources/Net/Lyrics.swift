import Foundation

struct Lyrics: Equatable {
    var synced: String?
    var plain: String?
}

struct LyricLine: Identifiable, Equatable {
    struct Word: Equatable {
        let text: String
        let offset: Double?
    }

    let id: Int
    let time: Double
    let words: [Word]
    let end: Double?

    var text: String { words.map(\.text).joined(separator: " ") }

    func wordOnsets(span: Double) -> [Double] {
        guard !words.isEmpty else { return [] }
        let lastMark = words.compactMap(\.offset).max() ?? 0
        let estimate = min(10, Double(words.count) * 0.6 + 0.6)
        let limit = max(lastMark, min(span, end ?? max(estimate, lastMark + 0.35)))
        var first = 0
        var from = words.first?.offset ?? 0
        var onsets: [Double] = []
        for index in 1...words.count {
            guard let mark = index == words.count ? limit : words[index].offset else { continue }
            let to = max(from, mark)
            let weights = words[first..<index].map { max(1, $0.text.count) }
            let total = Double(weights.reduce(0, +))
            var elapsed = from
            for weight in weights {
                onsets.append(elapsed)
                elapsed += (to - from) * Double(weight) / total
            }
            first = index
            from = to
        }
        return onsets
    }
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
        let rows = text.split(whereSeparator: \.isNewline)
        let offset = rows.lazy.compactMap { row -> Double? in
            let tag = row.trimmingCharacters(in: .whitespaces)
            guard tag.hasPrefix("[offset:"), tag.hasSuffix("]"),
                  let ms = Int(tag.dropFirst(8).dropLast().trimmingCharacters(in: .whitespaces))
            else { return nil }
            return Double(ms) / 1000
        }.first ?? 0
        var timed: [LyricLine] = []
        for raw in rows {
            var rest = Substring(raw).drop(while: { $0 == " " })
            var stamps: [Double] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let stamp = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                if let t = seconds(stamp) { stamps.append(t) }
            }
            guard let start = stamps.first else { continue }
            let cue = parseWords(rest, start: start)
            for time in stamps {
                timed.append(LyricLine(id: timed.count, time: time - offset, words: cue.words, end: cue.end))
            }
        }
        return timed.sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
            .enumerated().map { id, line in LyricLine(id: id, time: line.time, words: line.words, end: line.end) }
    }

    private static func parseWords(_ text: Substring, start: Double) -> (words: [LyricLine.Word], end: Double?) {
        var words: [LyricLine.Word] = []
        var cue: Double?
        var segment = text.startIndex
        func append(_ part: Substring) {
            for word in part.split(whereSeparator: \.isWhitespace) {
                words.append(LyricLine.Word(text: String(word), offset: cue))
                cue = nil
            }
        }
        for opening in text.indices where text[opening] == "<" {
            let after = text.index(after: opening)
            guard let closing = text[after...].firstIndex(of: ">"),
                  let stamp = seconds(text[after..<closing]) else { continue }
            append(text[segment..<opening])
            cue = max(0, stamp - start)
            segment = text.index(after: closing)
        }
        append(text[segment...])
        return (words, cue)
    }

    /// "01:02.50" → 62.5
    private static func seconds(_ stamp: Substring) -> Double? {
        let parts = stamp.split(separator: ":")
        guard parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
        let time = m * 60 + s
        return time.isFinite && time >= 0 ? time : nil
    }

    /// Split a shared timestamp among its rows in their original order.
    static func displayTimeline(_ lines: [LyricLine], duration: Double) -> [LyricLine] {
        var timed = lines
        var start = lines.startIndex
        while start < lines.endIndex {
            let time = lines[start].time
            var end = start + 1
            while end < lines.endIndex, lines[end].time == time { end += 1 }
            if end > start + 1 && lines[start..<end].allSatisfy({ $0.words.allSatisfy { $0.offset == nil } }) {
                let span = lineSpan(lines[start], in: lines, duration: duration)
                for index in (start + 1)..<end {
                    let line = lines[index]
                    let offset = span * Double(index - start) / Double(end - start)
                    timed[index] = LyricLine(id: line.id, time: time + offset, words: line.words, end: line.end)
                }
            }
            start = end
        }
        return timed
    }

    /// Length of the highlight sweep for a line from a line-timed transcript.
    static func lineSpan(_ line: LyricLine, in lines: [LyricLine], duration: Double) -> Double {
        let next = lines.first { $0.time > line.time }?.time
        if let next { return next - line.time }
        return duration.isFinite && duration > line.time ? duration - line.time : 3
    }

    /// the line being sung at `time`
    static func current(_ lines: [LyricLine], at time: Double) -> Int? {
        var found: Int?
        for line in lines {
            if line.time <= time { found = line.id } else { break }
        }
        return found
    }
}

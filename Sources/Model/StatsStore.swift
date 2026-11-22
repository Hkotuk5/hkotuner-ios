import Foundation
import SwiftUI

/// What was listened to on this phone: plays and minutes per song, minutes
/// per day, plays per month. The rules of the desktop's stats.rs and smart.rs,
/// in a file of its own (Application Support/stats.json).
@MainActor
final class StatsStore: ObservableObject {
    static let shared = StatsStore()
    static let maxTracks = 3000
    static let maxDays = 400
    static let maxMonths = 14

    struct TrackStat: Codable {
        var track: Track
        var plays: Int = 0
        var seconds: Double = 0
        /// when it was last counted, seconds since 1970
        var last: Double = 0
    }

    private struct Saved: Codable {
        var tracks: [String: TrackStat] = [:]
        var days: [String: Double] = [:]
        var months: [String: [String: Int]] = [:]
    }

    @Published private var data = Saved()
    private let fileURL: URL
    private var unsaved: Double = 0

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stats.json")
        if let raw = try? Data(contentsOf: self.fileURL), let saved = try? JSONDecoder().decode(Saved.self, from: raw) {
            data = saved
        }
    }

    // MARK: counting

    func listen(_ track: Track, seconds: Double) {
        guard seconds > 0 else { return }
        let day = Self.dayKey(Date())
        data.days[day, default: 0] += seconds
        var stat = data.tracks[track.id] ?? TrackStat(track: track)
        stat.seconds += seconds
        stat.track = track
        data.tracks[track.id] = stat
        unsaved += seconds
        if unsaved >= 30 { save() }
    }

    func countPlay(_ track: Track) {
        var stat = data.tracks[track.id] ?? TrackStat(track: track)
        stat.plays += 1
        stat.last = Date().timeIntervalSince1970
        stat.track = track
        data.tracks[track.id] = stat
        data.months[Self.monthKey(Date()), default: [:]][track.id, default: 0] += 1
        save()
    }

    func save() {
        unsaved = 0
        prune()
        try? JSONEncoder().encode(data).write(to: fileURL, options: .atomic)
    }

    func reset() {
        data = Saved()
        save()
    }

    private func prune() {
        if data.tracks.count > Self.maxTracks {
            let keep = data.tracks.sorted { ($0.value.plays, $0.value.last) > ($1.value.plays, $1.value.last) }.prefix(Self.maxTracks)
            data.tracks = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if data.days.count > Self.maxDays {
            for key in data.days.keys.sorted().prefix(data.days.count - Self.maxDays) { data.days[key] = nil }
        }
        if data.months.count > Self.maxMonths {
            for key in data.months.keys.sorted().prefix(data.months.count - Self.maxMonths) { data.months[key] = nil }
        }
    }

    // MARK: reading

    var isEmpty: Bool { data.tracks.isEmpty }

    /// listened seconds over the last `days` days, today included
    func seconds(lastDays days: Int, now: Date = Date()) -> Double {
        (0..<days).reduce(0) { sum, back in
            let day = Calendar.current.date(byAdding: .day, value: -back, to: now) ?? now
            return sum + (data.days[Self.dayKey(day)] ?? 0)
        }
    }

    /// each of the last 7 days, oldest first
    func week(now: Date = Date()) -> [(day: Date, seconds: Double)] {
        (0..<7).reversed().map { back in
            let day = Calendar.current.date(byAdding: .day, value: -back, to: now) ?? now
            return (day, data.days[Self.dayKey(day)] ?? 0)
        }
    }

    /// days in a row, up to today, with at least a minute of music
    func streak(now: Date = Date()) -> Int {
        var count = 0
        var day = now
        if (data.days[Self.dayKey(day)] ?? 0) < 60 {
            day = Calendar.current.date(byAdding: .day, value: -1, to: day) ?? day
        }
        while (data.days[Self.dayKey(day)] ?? 0) >= 60 {
            count += 1
            day = Calendar.current.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return count
    }

    func topTracks(_ limit: Int = 10) -> [TrackStat] {
        Array(data.tracks.values.filter { $0.plays > 0 }
            .sorted { ($0.plays, $0.seconds) > ($1.plays, $1.seconds) }
            .prefix(limit))
    }

    /// the month's most played songs, with their plays
    func topTracks(month: Date, limit: Int = 10) -> [(track: Track, plays: Int)] {
        let counts = data.months[Self.monthKey(month)] ?? [:]
        let sorted = counts.sorted { $0.value > $1.value }.prefix(limit)
        var out: [(track: Track, plays: Int)] = []
        for (id, plays) in sorted {
            if let stat = data.tracks[id] { out.append((stat.track, plays)) }
        }
        return out
    }

    func topArtists(_ limit: Int = 8) -> [(name: String, seconds: Double)] {
        var by: [String: Double] = [:]
        for stat in data.tracks.values {
            let name = LyricsService.mainArtist(stat.track.artist)
            if !name.isEmpty { by[name, default: 0] += stat.seconds }
        }
        return by.sorted { $0.value > $1.value }.prefix(limit).map { (name: $0.key, seconds: $0.value) }
    }

    func plays(_ track: Track) -> Int { data.tracks[track.id]?.plays ?? 0 }

    var totalSeconds: Double { data.days.values.reduce(0, +) }

    // MARK: playlists the app fills by itself (smart.rs)

    /// heard most often
    func frequent(hidden: Set<String>) -> [Track] {
        Array(data.tracks.values.filter { $0.plays >= 3 && !hidden.contains($0.track.id) }
            .sorted { ($0.plays, $0.last) > ($1.plays, $1.last) }
            .prefix(50)).map(\.track)
    }

    /// liked songs and old favourites not heard for a month
    func forgotten(liked: [Track], hidden: Set<String>, now: Date = Date()) -> [Track] {
        let cutoff = now.timeIntervalSince1970 - 30 * 86400
        var out: [Track] = []
        var seen = Set<String>()
        for track in liked where !hidden.contains(track.id) {
            let last = data.tracks[track.id]?.last ?? 0
            // only songs heard here before: a fresh phone has not "forgotten" anything
            if data.tracks[track.id] != nil && last < cutoff && seen.insert(track.id).inserted { out.append(track) }
        }
        for stat in data.tracks.values.sorted(by: { $0.plays > $1.plays }) where stat.plays >= 3 && stat.last < cutoff {
            if !hidden.contains(stat.track.id) && seen.insert(stat.track.id).inserted { out.append(stat.track) }
        }
        return Array(out.prefix(50))
    }

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func monthKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}

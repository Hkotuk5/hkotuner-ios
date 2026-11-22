import Foundation
import SwiftUI

/// YouTube Music's start page; personal when signed in. Kept for half an hour.
@MainActor
final class HomeFeed: ObservableObject {
    static let shared = HomeFeed()

    @Published private(set) var shelves: [HomeShelf] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var loadedAt: Date?

    func load(force: Bool = false) async {
        if loading { return }
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 1800, !shelves.isEmpty { return }
        loading = true
        defer { loading = false }
        do {
            let found = try await YTMusic.home(auth: YTAuth.isSignedIn)
            shelves = Array(found.prefix(12))
            error = nil
            loadedAt = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func forget() {
        shelves = []
        loadedAt = nil
    }
}

struct Release: Codable, Hashable, Identifiable {
    var card: MusicCard
    var artist: String
    var id: String { card.id }
}

/// «Новое у ваших исполнителей»: singles and albums of this year and the last
/// from the newest followed artists, as on the desktop (hk-app/src/releases.rs).
@MainActor
final class NewReleases: ObservableObject {
    static let shared = NewReleases()
    static let artistsAsked = 12
    static let perArtist = 2
    static let shown = 12
    private static let key = "releases.v1"

    private struct Saved: Codable {
        var at: Date
        var artists: [String]
        var items: [Release]
    }

    @Published private(set) var items: [Release] = []
    @Published private(set) var loading = false

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            items = saved.items
        }
    }

    func load(_ artists: [FollowedArtist]) async {
        let asked = Array(artists.prefix(Self.artistsAsked))
        guard !asked.isEmpty else { items = []; return }
        let ids = asked.map(\.id)
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Saved.self, from: data),
           saved.artists == ids, Date().timeIntervalSince(saved.at) < 12 * 3600 {
            items = saved.items
            return
        }
        if loading { return }
        loading = true
        defer { loading = false }
        let thisYear = Calendar.current.component(.year, from: Date())
        var found: [(Int, Release)] = []
        await withTaskGroup(of: [(Int, Release)].self) { group in
            var next = 0
            while next < min(3, asked.count) {
                let artist = asked[next]
                next += 1
                group.addTask { await NewReleases.fresh(artist, since: thisYear - 1) }
            }
            while let part = await group.next() {
                found += part
                if next < asked.count {
                    let artist = asked[next]
                    next += 1
                    group.addTask { await NewReleases.fresh(artist, since: thisYear - 1) }
                }
            }
        }
        items = Array(found.sorted { $0.0 > $1.0 }.map { $0.1 }.prefix(Self.shown))
        if let data = try? JSONEncoder().encode(Saved(at: Date(), artists: ids, items: items)) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    nonisolated private static func fresh(_ artist: FollowedArtist, since year: Int) async -> [(Int, Release)] {
        guard let page = try? await YTMusic.artist(artist.id) else { return [] }
        let cards = (page.singles + page.albums).compactMap { card -> (Int, Release)? in
            guard let y = card.year, y >= year else { return nil }
            return (y, Release(card: card, artist: page.name.isEmpty ? artist.name : page.name))
        }
        return Array(cards.sorted { $0.0 > $1.0 }.prefix(2))
    }
}

/// A newer .ipa on GitHub: checked once a day, shown in the settings.
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()
    static let api = URL(string: "https://api.github.com/repos/Hkotuk5/hkotuner-ios/releases/latest")!

    @Published private(set) var latest: String? = UserDefaults.standard.string(forKey: "update.latest")
    @Published private(set) var page: URL? = UserDefaults.standard.string(forKey: "update.page").flatMap(URL.init(string:))
    @Published private(set) var checking = false

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    var hasUpdate: Bool { latest.map { Updates.newer($0, than: Updates.current) } ?? false }

    func checkIfDue() async {
        let last = UserDefaults.standard.object(forKey: "update.checkedAt") as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > 86400 { await check() }
    }

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        guard let root = try? await HTTP.getJSON(Self.api, headers: ["User-Agent": HTTP.appAgent, "Accept": "application/vnd.github+json"], what: "GitHub"),
              let tag = JSONTree.string(root, "/tag_name") else { return }
        latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        page = JSONTree.string(root, "/html_url").flatMap(URL.init(string:))
        UserDefaults.standard.set(latest, forKey: "update.latest")
        UserDefaults.standard.set(page?.absoluteString, forKey: "update.page")
        UserDefaults.standard.set(Date(), forKey: "update.checkedAt")
    }

    /// "0.10.0" is newer than "0.9.2"
    nonisolated static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0
            let q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

import Combine
import Foundation
import SwiftUI

/// The library on this phone: likes, playlists, history, own files, hidden
/// songs. One JSON file in Application Support, written whole on every change.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()
    static let historyLimit = 200

    @Published private(set) var library: Library
    @Published var lastError: String?
    let sharedChanges = PassthroughSubject<Void, Never>()

    private let fileURL: URL

    /// keep liked songs on the phone for listening without internet
    var offlineLikes: Bool {
        get { UserDefaults.standard.object(forKey: "offlineLikes") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "offlineLikes"); objectWillChange.send() }
    }

    init(fileURL: URL? = nil) {
        let url = fileURL ?? {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("library.json")
        }()
        self.fileURL = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Library.self, from: data) {
            library = saved
        } else {
            library = Library()
        }
    }

    private func change(_ edit: (inout Library) -> Void) {
        var copy = library
        edit(&copy)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(copy).write(to: fileURL, options: .atomic)
            let sharedChanged = library.liked != copy.liked || library.playlists != copy.playlists
            library = copy
            if sharedChanged { sharedChanges.send(()) }
        } catch {
            lastError = "Не удалось сохранить библиотеку: \(error.localizedDescription)"
        }
    }

    // MARK: likes and hidden songs

    func applySync(_ shared: SharedLibrary) throws {
        var copy = library
        shared.apply(to: &copy)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(copy).write(to: fileURL, options: .atomic)
        library = copy
    }

    func isLiked(_ track: Track) -> Bool { library.liked.contains { $0.id == track.id } }
    func isDisliked(_ track: Track) -> Bool { library.disliked.contains { $0.id == track.id } }

    func toggleLike(_ track: Track) {
        if isLiked(track) {
            change { $0.liked.removeAll { $0.id == track.id } }
        } else {
            change {
                $0.liked.insert(track, at: 0)
                $0.disliked.removeAll { $0.id == track.id }
            }
            if offlineLikes, Downloads.supports(track) {
                Task(priority: .utility) { try? await Downloads.shared.keep(track) }
            }
        }
    }

    func removeLiked(at offsets: IndexSet) {
        change { $0.liked.remove(atOffsets: offsets) }
    }

    func moveLiked(from source: IndexSet, to destination: Int) {
        change { $0.liked.move(fromOffsets: source, toOffset: destination) }
    }

    /// "не нравится": kept out of the wave and the radio, still found by search
    func toggleDislike(_ track: Track) {
        if isDisliked(track) {
            change { $0.disliked.removeAll { $0.id == track.id } }
        } else {
            change {
                $0.disliked.insert(track, at: 0)
                $0.liked.removeAll { $0.id == track.id }
                if $0.disliked.count > 2000 { $0.disliked.removeLast($0.disliked.count - 2000) }
            }
        }
    }

    // MARK: history

    func pushHistory(_ track: Track) {
        change {
            $0.history.removeAll { $0.id == track.id }
            $0.history.insert(track, at: 0)
            if $0.history.count > Self.historyLimit { $0.history.removeLast($0.history.count - Self.historyLimit) }
        }
    }

    func clearHistory() { change { $0.history.removeAll() } }

    // MARK: playlists

    func playlist(_ id: String) -> Playlist? { library.playlists.first { $0.id == id } }

    @discardableResult
    func createPlaylist(_ name: String, tracks: [Track] = []) -> String {
        let id = "pl-\(UUID().uuidString.lowercased())"
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(id: id, name: clean.isEmpty ? "Новый плейлист" : String(clean.prefix(100)),
                                tracks: tracks, createdAt: Self.nowMs())
        change { $0.playlists.insert(playlist, at: 0) }
        return id
    }

    func renamePlaylist(_ id: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        editPlaylist(id) { $0.name = String(clean.prefix(100)) }
    }

    func deletePlaylist(_ id: String) { change { $0.playlists.removeAll { $0.id == id } } }

    func add(_ tracks: [Track], to id: String) {
        editPlaylist(id) { playlist in
            for track in tracks where !playlist.tracks.contains(where: { $0.id == track.id }) {
                playlist.tracks.append(track)
            }
        }
    }

    func removeTracks(at offsets: IndexSet, from id: String) {
        editPlaylist(id) { $0.tracks.remove(atOffsets: offsets) }
    }

    func moveTracks(in id: String, from source: IndexSet, to destination: Int) {
        editPlaylist(id) { $0.tracks.move(fromOffsets: source, toOffset: destination) }
    }

    private func editPlaylist(_ id: String, _ edit: (inout Playlist) -> Void) {
        change { lib in
            guard let i = lib.playlists.firstIndex(where: { $0.id == id }) else { return }
            edit(&lib.playlists[i])
        }
    }

    // MARK: own files

    func addLocal(_ tracks: [Track]) {
        change { lib in
            for track in tracks {
                if let i = lib.local.firstIndex(where: { $0.id == track.id }) {
                    lib.local[i] = track
                } else {
                    lib.local.insert(track, at: 0)
                }
            }
        }
    }

    func removeLocal(at offsets: IndexSet) {
        let gone = offsets.map { library.local[$0] }
        change { $0.local.remove(atOffsets: offsets) }
        for track in gone { LocalFiles.delete(track) }
    }

    // MARK: artists

    func isFollowed(_ id: String) -> Bool { library.artists.contains { $0.id == id } }

    func toggleFollow(_ artist: FollowedArtist) {
        if isFollowed(artist.id) {
            change { $0.artists.removeAll { $0.id == artist.id } }
        } else {
            change { $0.artists.insert(artist, at: 0) }
        }
    }

    func unfollow(at offsets: IndexSet) { change { $0.artists.remove(atOffsets: offsets) } }

    // MARK: playlists that came from elsewhere

    /// a shared, imported or found playlist kept as one of the listener's own
    @discardableResult
    func keep(_ shared: SharedPlaylist) -> String {
        createPlaylist(shared.name, tracks: shared.tracks)
    }

    /// the YouTube Music account's likes and playlists, added to what is here.
    /// An account playlist keeps its id ("yt-VL…"), so importing again updates it.
    func importAccount(liked: [Track], playlists: [(id: String, name: String, tracks: [Track])]) -> (liked: Int, created: Int, updated: Int) {
        var likedAdded = 0
        var created = 0
        var updated = 0
        change { lib in
            let known = Set(lib.liked.map(\.id))
            let fresh = liked.filter { !known.contains($0.id) }
            likedAdded = fresh.count
            // an empty library takes the account's order; otherwise new likes go after the ones here
            if lib.liked.isEmpty { lib.liked = fresh } else { lib.liked.append(contentsOf: fresh) }
            for p in playlists {
                let id = "yt-\(p.id)"
                if let i = lib.playlists.firstIndex(where: { $0.id == id }) {
                    let theirs = Set(p.tracks.map(\.id))
                    let mine = lib.playlists[i].tracks.filter { !theirs.contains($0.id) }
                    lib.playlists[i].tracks = p.tracks + mine
                    lib.playlists[i].name = p.name
                    updated += 1
                } else {
                    lib.playlists.append(Playlist(id: id, name: String(p.name.prefix(100)), tracks: p.tracks, createdAt: Self.nowMs()))
                    created += 1
                }
            }
        }
        return (likedAdded, created, updated)
    }

    // MARK: playlist covers (a picture of the listener's own, on this phone)

    static let coversDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    @Published private(set) var coverVersion = 0

    func coverURL(_ playlistId: String) -> URL? {
        let url = Self.coversDir.appendingPathComponent("\(Self.safeName(playlistId)).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func setCover(_ playlistId: String, jpeg: Data?) {
        let url = Self.coversDir.appendingPathComponent("\(Self.safeName(playlistId)).jpg")
        if let jpeg {
            try? jpeg.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        coverVersion += 1
    }

    private static func safeName(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.prefix(120))
    }

    // MARK: a copy each week in Files → hkotuner → Backups

    static var backupsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Backups", isDirectory: true)
    }

    var autoBackup: Bool {
        get { UserDefaults.standard.object(forKey: "autoBackup") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoBackup"); objectWillChange.send() }
    }

    var lastAutoBackup: Date? { UserDefaults.standard.object(forKey: "autoBackup.at") as? Date }

    func autoBackupIfDue() {
        guard autoBackup, !(library.liked.isEmpty && library.playlists.isEmpty) else { return }
        if let last = lastAutoBackup, Date().timeIntervalSince(last) < 7 * 86400 { return }
        do {
            let made = try exportBackup()
            let dir = Self.backupsDir
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent(made.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: made, to: target)
            UserDefaults.standard.set(Date(), forKey: "autoBackup.at")
            // the four newest are enough
            let old = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasPrefix("hkotuner-iphone-") && $0.hasSuffix(".json") }
                .sorted().dropLast(4)
            for name in old { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        } catch {
            lastError = "Автокопия не сохранилась: \(error.localizedDescription)"
        }
    }

    // MARK: moving between the phone and the computer

    /// a desktop backup (Настройки → Данные) or its library.json, added to what is here;
    /// the computer's own music files cannot come along
    func importDesktop(_ data: Data) throws -> (liked: Int, playlists: Int) {
        let incoming: Library
        if let backup = try? JSONDecoder().decode(DesktopBackup.self, from: data), backup.kind == "hkotuner-backup" {
            incoming = backup.library
        } else if let lib = try? JSONDecoder().decode(Library.self, from: data),
                  !(lib.liked.isEmpty && lib.playlists.isEmpty && lib.history.isEmpty) {
            incoming = lib
        } else {
            throw HKError("Это не библиотека hkotuner")
        }
        let movable: (Track) -> Bool = { !$0.isLocal }
        var likedAdded = 0
        var playlistsAdded = 0
        change { lib in
            for track in incoming.liked.filter(movable) where !lib.liked.contains(where: { $0.id == track.id }) {
                lib.liked.append(track)
                likedAdded += 1
            }
            for track in incoming.disliked.filter(movable) where !lib.disliked.contains(where: { $0.id == track.id }) {
                lib.disliked.append(track)
            }
            for track in incoming.history.filter(movable) where !lib.history.contains(where: { $0.id == track.id }) {
                lib.history.append(track)
            }
            if lib.history.count > Self.historyLimit { lib.history.removeLast(lib.history.count - Self.historyLimit) }
            for artist in incoming.artists where !lib.artists.contains(where: { $0.id == artist.id }) {
                lib.artists.append(artist)
            }
            for var playlist in incoming.playlists {
                playlist.tracks = playlist.tracks.filter(movable)
                playlist.cover = nil
                if let i = lib.playlists.firstIndex(where: { $0.id == playlist.id }) {
                    for track in playlist.tracks where !lib.playlists[i].tracks.contains(where: { $0.id == track.id }) {
                        lib.playlists[i].tracks.append(track)
                    }
                } else if !playlist.tracks.isEmpty {
                    lib.playlists.append(playlist)
                    playlistsAdded += 1
                }
            }
        }
        return (likedAdded, playlistsAdded)
    }

    /// a backup file in the desktop's format (its restore replaces the whole library there)
    func exportBackup() throws -> URL {
        var lib = library
        lib.local = []
        lib.liked.removeAll(where: \.isAudioStream)
        lib.history.removeAll(where: \.isAudioStream)
        for index in lib.playlists.indices {
            lib.playlists[index].tracks.removeAll(where: \.isAudioStream)
        }
        let libraryJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(lib))
        let backup: [String: Any] = [
            "kind": "hkotuner-backup",
            "version": 1,
            "createdAt": Self.nowMs(),
            "appVersion": "ios-\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")",
            "library": libraryJSON,
        ]
        let data = try JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted])
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hkotuner-iphone-\(stamp).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
}

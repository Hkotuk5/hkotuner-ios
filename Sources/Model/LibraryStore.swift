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
        library = copy
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(copy).write(to: fileURL, options: .atomic)
        } catch {
            lastError = "Не удалось сохранить библиотеку: \(error.localizedDescription)"
        }
    }

    // MARK: likes and hidden songs

    func isLiked(_ track: Track) -> Bool { library.liked.contains { $0.id == track.id } }
    func isDisliked(_ track: Track) -> Bool { library.disliked.contains { $0.id == track.id } }

    func toggleLike(_ track: Track) {
        if isLiked(track) {
            change { $0.liked.removeAll { $0.id == track.id } }
            if let id = track.videoId { AudioCache.removeOffline(videoId: id) }
        } else {
            change {
                $0.liked.insert(track, at: 0)
                $0.disliked.removeAll { $0.id == track.id }
            }
            if offlineLikes, let id = track.videoId {
                Task.detached(priority: .utility) { try? await AudioCache.shared.keepOffline(videoId: id) }
            }
        }
    }

    func removeLiked(at offsets: IndexSet) {
        let gone = offsets.map { library.liked[$0] }
        change { $0.liked.remove(atOffsets: offsets) }
        for track in gone { if let id = track.videoId { AudioCache.removeOffline(videoId: id) } }
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

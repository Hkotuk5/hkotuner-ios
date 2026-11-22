import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { LikedView() } label: {
                        row("Любимые", "heart.fill", library.library.liked.count)
                    }
                    NavigationLink { HistoryView() } label: {
                        row("История", "clock.fill", library.library.history.count)
                    }
                    NavigationLink { LocalFilesView() } label: {
                        row("Мои файлы", "folder.fill", library.library.local.count)
                    }
                    NavigationLink { HiddenView() } label: {
                        row("Скрытые песни", "hand.thumbsdown.fill", library.library.disliked.count)
                    }
                }
                Section("Плейлисты") {
                    Button { naming = true } label: {
                        Label("Новый плейлист", systemImage: "plus")
                    }
                    ForEach(library.library.playlists) { playlist in
                        NavigationLink { PlaylistView(playlistId: playlist.id) } label: {
                            HStack(spacing: 12) {
                                Artwork(url: playlist.tracks.first?.thumbnailURL, size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name).lineLimit(1)
                                    Text("\(playlist.tracks.count) треков").font(.caption).foregroundStyle(Theme.muted)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { library.library.playlists[$0].id }
                        for id in ids { library.deletePlaylist(id) }
                    }
                }
                if let error = library.lastError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Библиотека")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Настройки")
                }
            }
            .alert("Новый плейлист", isPresented: $naming) {
                TextField("Название", text: $name)
                Button("Создать") { library.createPlaylist(name); name = "" }
                Button("Отмена", role: .cancel) { name = "" }
            }
        }
    }

    private func row(_ title: String, _ icon: String, _ count: Int) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text("\(count)").foregroundStyle(Theme.muted)
        }
    }
}

/// a list of songs with play / shuffle buttons on top
struct TrackListView: View {
    @EnvironmentObject private var player: Player
    let title: String
    let tracks: [Track]
    var empty = "Пока пусто"
    var onDelete: ((IndexSet) -> Void)?
    var onMove: ((IndexSet, Int) -> Void)?

    var body: some View {
        List {
            if tracks.isEmpty {
                Text(empty).foregroundStyle(Theme.muted)
            } else {
                HStack(spacing: 12) {
                    Button { player.play(tracks) } label: {
                        Label("Слушать", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { player.shuffle(tracks) } label: {
                        Label("Вперемешку", systemImage: "shuffle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .foregroundStyle(Color.black)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                TrackRow(track: track)
                    .onTapGesture { player.play(tracks, at: i) }
                    .trackMenu(track)
            }
            .onDelete(perform: onDelete)
            .onMove(perform: onMove)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(title)
        .toolbar {
            if onMove != nil && !tracks.isEmpty { EditButton() }
        }
    }
}

struct LikedView: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        TrackListView(
            title: "Любимые",
            tracks: library.library.liked,
            empty: "Нажми ♥ у песни, и она будет здесь. Любимые сохраняются на телефон и играют без интернета.",
            onDelete: { library.removeLiked(at: $0) },
            onMove: { library.moveLiked(from: $0, to: $1) }
        )
    }
}

struct HistoryView: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        TrackListView(title: "История", tracks: library.library.history, empty: "Здесь будут последние 200 песен")
            .toolbar {
                if !library.library.history.isEmpty {
                    Button("Очистить", role: .destructive) { library.clearHistory() }
                }
            }
    }
}

struct HiddenView: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        List {
            if library.library.disliked.isEmpty {
                Text("Песни с «Не нравится» не попадают в волну и похожие. Здесь их можно вернуть.")
                    .foregroundStyle(Theme.muted)
            }
            ForEach(library.library.disliked) { track in
                TrackRow(track: track)
                    .swipeActions {
                        Button("Вернуть") { library.toggleDislike(track) }.tint(Theme.accent)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Скрытые песни")
    }
}

struct PlaylistView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let playlistId: String
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        let playlist = library.playlist(playlistId)
        TrackListView(
            title: playlist?.name ?? "Плейлист",
            tracks: playlist?.tracks ?? [],
            empty: "Добавляй песни долгим нажатием → «В плейлист…»",
            onDelete: { library.removeTracks(at: $0, from: playlistId) },
            onMove: { library.moveTracks(in: playlistId, from: $0, to: $1) }
        )
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button("Переименовать") { name = playlist?.name ?? ""; renaming = true }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Удалить плейлист", role: .destructive) {
                    library.deletePlaylist(playlistId)
                    dismiss()
                }
            }
        }
        .alert("Название плейлиста", isPresented: $renaming) {
            TextField("Название", text: $name)
            Button("Сохранить") { library.renamePlaylist(playlistId, to: name) }
            Button("Отмена", role: .cancel) {}
        }
    }
}

struct LocalFilesView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var importing = false
    @State private var busy = false

    var body: some View {
        TrackListView(
            title: "Мои файлы",
            tracks: library.library.local,
            empty: "Добавь mp3, m4a, flac или wav из «Файлов». Ещё можно положить их в Файлы → На iPhone → hkotuner → Music и нажать «Обновить».",
            onDelete: { library.removeLocal(at: $0) }
        )
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if busy { ProgressView() }
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Обновить")
                Button { importing = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Добавить файлы")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            busy = true
            Task {
                library.addLocal(await LocalFiles.importFiles(urls))
                busy = false
            }
        }
    }

    private func refresh() {
        busy = true
        Task {
            library.addLocal(await LocalFiles.scan())
            busy = false
        }
    }
}

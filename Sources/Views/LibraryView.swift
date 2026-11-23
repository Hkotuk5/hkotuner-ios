import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject private var downloads = Downloads.shared
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var account: YTAccount
    @State private var naming = false
    @State private var name = ""
    @State private var importingFile = false
    @State private var pastingLink = false
    @State private var link = ""
    @State private var linkToOpen: String?
    @State private var incoming: SharedPlaylist?
    @State private var note: String?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        tile("Любимые", "heart.fill", songsText(library.library.liked.count)) { LikedView() }
                        tile("История", "clock.fill", songsText(library.library.history.count)) { HistoryView() }
                        tile("Исполнители", "music.mic", "\(library.library.artists.count)") { ArtistsView() }
                        tile("Мои файлы", "folder.fill", songsText(library.library.local.count)) { LocalFilesView() }
                        tile("Скачанные", "arrow.down.circle.fill", songsText(downloads.tracks(in: library.library).count)) { DownloadedView() }
                        tile("Статистика", "chart.bar.fill", "итоги") { StatsView() }
                        tile("Скрытые", "hand.thumbsdown.fill", songsText(library.library.disliked.count)) { HiddenView() }
                    }
                    .padding(.horizontal, 16)

                    if account.isSignedIn {
                        accountCard.padding(.horizontal, 16)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Плейлисты").font(.title3.weight(.bold)).foregroundStyle(Theme.ink)
                            Spacer()
                            Menu {
                                Button { naming = true } label: { Label("Новый плейлист", systemImage: "plus") }
                                Button { pastingLink = true } label: { Label("По ссылке (YouTube, Spotify)", systemImage: "link") }
                                Button { importingFile = true } label: { Label("Из файла .hkplaylist", systemImage: "doc") }
                            } label: {
                                Image(systemName: "plus.circle.fill").font(.title2)
                            }
                            .accessibilityLabel("Добавить плейлист")
                        }
                        .padding(.horizontal, 16)
                        if library.library.playlists.isEmpty {
                            EmptyNote(icon: "music.note.list", title: "Плейлистов пока нет",
                                      text: "Создай свой, перенеси по ссылке или войди в YouTube Music в настройках — твои плейлисты появятся здесь.")
                        } else {
                            LazyVStack(spacing: 4) {
                                ForEach(library.library.playlists) { playlist in
                                    NavigationLink { PlaylistView(playlistId: playlist.id) } label: { playlistRow(playlist) }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button(role: .destructive) { library.deletePlaylist(playlist.id) } label: {
                                                Label("Удалить", systemImage: "trash")
                                            }
                                        }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    if let note {
                        Text(note).font(.footnote).foregroundStyle(Theme.accent).padding(.horizontal, 16)
                    }
                    if let error = library.lastError {
                        Text(error).font(.footnote).foregroundStyle(.orange).padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 12)
            }
            .background(ScreenBackground())
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
            .alert("Ссылка на плейлист", isPresented: $pastingLink) {
                TextField("https://…", text: $link)
                Button("Открыть") {
                    linkToOpen = link
                    link = ""
                }
                Button("Отмена", role: .cancel) { link = "" }
            } message: {
                Text("YouTube, YouTube Music, Spotify или ссылка hkotuner")
            }
            .sheet(item: Binding(get: { linkToOpen.map(LinkBox.init) }, set: { linkToOpen = $0?.text })) { box in
                LinkImportView(link: box.text)
            }
            .sheet(item: $incoming) { IncomingPlaylistView(shared: $0) }
            .fileImporter(isPresented: $importingFile, allowedContentTypes: [.hkPlaylist, .json, .data], allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    incoming = try ShareCodec.readFile(try Data(contentsOf: url))
                } catch {
                    note = error.localizedDescription
                }
            }
        }
    }

    private var accountCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill").font(.title2).foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("YouTube Music").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(account.importing ?? account.note ?? "Перенести лайки и плейлисты аккаунта")
                    .font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
            }
            Spacer()
            if account.importing != nil {
                ProgressView()
            } else {
                Button("Перенести") { Task { await account.importLibrary(into: library) } }
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
    }

    private func tile<D: View>(_ title: String, _ icon: String, _ detail: String, @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink(destination: destination) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.title3).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(Theme.ink)
                    Text(detail).font(.caption).foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
        }
        .buttonStyle(.plain)
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            PlaylistCover(playlist: playlist, size: 56, radius: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name).font(.body.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(playlist.id.hasPrefix("yt-") ? "YouTube Music · \(songsText(playlist.tracks.count))" : songsText(playlist.tracks.count))
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct LinkBox: Identifiable {
    let text: String
    var id: String { text }
}

extension UTType {
    static let hkPlaylist = UTType(exportedAs: "uk.hkot.hkplaylist", conformingTo: .json)
}

/// a list of songs with play / shuffle buttons on top
struct TrackListView: View {
    @EnvironmentObject private var player: Player
    let title: String
    let tracks: [Track]
    var empty = "Пока пусто"
    var onDelete: ((IndexSet) -> Void)?
    var onMove: ((IndexSet, Int) -> Void)?
    var header: AnyView? = nil

    var body: some View {
        List {
            if let header {
                header.listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if tracks.isEmpty {
                EmptyNote(icon: "music.note", title: "Пока пусто", text: empty)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                PlayButtons(tracks: tracks)
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
        .screenBackground()
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
            empty: "Нажми ♥ у песни, и она будет здесь.",
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
                EmptyNote(icon: "hand.thumbsdown", title: "Скрытых нет",
                          text: "Песни с «Не нравится» не попадают в волну и похожие. Здесь их можно вернуть.")
                    .listRowBackground(Color.clear)
            }
            ForEach(library.library.disliked) { track in
                TrackRow(track: track)
                    .swipeActions {
                        Button("Вернуть") { library.toggleDislike(track) }.tint(Theme.accent)
                    }
            }
        }
        .listStyle(.plain)
        .screenBackground()
        .navigationTitle("Скрытые песни")
    }
}

struct ArtistsView: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        List {
            if library.library.artists.isEmpty {
                EmptyNote(icon: "music.mic", title: "Ни на кого не подписан",
                          text: "Открой исполнителя (долгое нажатие на песню → «Исполнитель») и нажми «Подписаться» — на главной появятся его новинки.")
                    .listRowBackground(Color.clear)
            }
            ForEach(library.library.artists) { artist in
                NavigationLink { ArtistView(artistId: artist.id, name: artist.name) } label: {
                    HStack(spacing: 12) {
                        Artwork(url: artist.thumbnail.flatMap(URL.init(string:)), size: 52, radius: 26)
                        Text(artist.name).foregroundStyle(Theme.ink)
                    }
                }
                .listRowBackground(Color.clear)
            }
            .onDelete { library.unfollow(at: $0) }
        }
        .listStyle(.plain)
        .screenBackground()
        .navigationTitle("Исполнители")
    }
}

struct PlaylistView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let playlistId: String
    @State private var renaming = false
    @State private var name = ""
    @State private var photo: PhotosPickerItem?
    @State private var picking = false
    @State private var shareFile: URL?

    var body: some View {
        let playlist = library.playlist(playlistId)
        TrackListView(
            title: playlist?.name ?? "Плейлист",
            tracks: playlist?.tracks ?? [],
            empty: "Добавляй песни долгим нажатием → «В плейлист…»",
            onDelete: { library.removeTracks(at: $0, from: playlistId) },
            onMove: { library.moveTracks(in: playlistId, from: $0, to: $1) },
            header: playlist.map { AnyView(header($0)) }
        )
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button { name = playlist?.name ?? ""; renaming = true } label: { Label("Переименовать", systemImage: "pencil") }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button { picking = true } label: { Label("Обложка", systemImage: "photo") }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(role: .destructive) {
                    library.deletePlaylist(playlistId)
                    library.setCover(playlistId, jpeg: nil)
                    dismiss()
                } label: { Label("Удалить плейлист", systemImage: "trash") }
            }
        }
        .photosPicker(isPresented: $picking, selection: $photo, matching: .images)
        .onChange(of: photo) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let jpeg = Self.squareJPEG(data) {
                    library.setCover(playlistId, jpeg: jpeg)
                }
                photo = nil
            }
        }
        .alert("Название плейлиста", isPresented: $renaming) {
            TextField("Название", text: $name)
            Button("Сохранить") { library.renamePlaylist(playlistId, to: name) }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func header(_ playlist: Playlist) -> some View {
        VStack(spacing: 14) {
            PlaylistCover(playlist: playlist, size: 210, radius: 18)
                .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
                .onTapGesture { picking = true }
            Text(playlist.name).font(.title2.weight(.bold)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
            Text(songsText(playlist.tracks.count)).font(.caption).foregroundStyle(Theme.muted)
            if !playlist.tracks.isEmpty {
                HStack(spacing: 18) {
                    if let link = URL(string: ShareCodec.makeLink(name: playlist.name, tracks: playlist.tracks)) {
                        ShareLink(item: link) { Label("Ссылка", systemImage: "link") }
                    }
                    Button {
                        shareFile = try? ShareCodec.makeFile(name: playlist.name, tracks: playlist.tracks)
                    } label: { Label("Файл", systemImage: "doc") }
                    if let shareFile {
                        ShareLink(item: shareFile) { Label("Отправить", systemImage: "square.and.arrow.up") }
                    }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                if ShareCodec.leftBehind(playlist.tracks) > 0 {
                    Text("Свои файлы с телефона по ссылке не уходят").font(.caption2).foregroundStyle(Theme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// the middle square of a photo, 600 px, as JPEG
    static func squareJPEG(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let side = min(image.size.width, image.size.height)
        let target = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: target)
        let out = renderer.image { _ in
            let scale = 600 / side
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (600 - drawn.width) / 2, y: (600 - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
        return out.jpegData(compressionQuality: 0.85)
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

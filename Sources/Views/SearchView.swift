import SwiftUI

struct SearchView: View {
    private enum Provider: String, CaseIterable, Identifiable {
        case youtube = "YouTube Music", soundCloud = "SoundCloud"
        var id: String { rawValue }
    }

    enum Scope: String, CaseIterable, Identifiable {
        case songs = "Песни", artists = "Исполнители", albums = "Альбомы", playlists = "Плейлисты"
        var id: String { rawValue }
    }

    @EnvironmentObject private var player: Player
    @State private var query = ""
    @State private var provider = Provider.youtube
    @State private var scope = Scope.songs
    @State private var songs: [Track] = []
    @State private var cards: [MusicCard] = []
    @State private var searching = false
    @State private var error: String?
    @State private var searched = ""
    @State private var linkImport: String?
    @State private var searchTask: Task<Void, Never>?
    @AppStorage("recentSearches") private var recentRaw = ""

    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        NavigationStack {
            List {
                Picker("Источник", selection: $provider) {
                    ForEach(Provider.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if let stream = Track.audioStream(from: query) {
                    Section {
                        Button { player.playSingle(stream) } label: {
                            Label("Воспроизвести аудиопоток", systemImage: "play.circle")
                                .font(.headline)
                        }
                    } footer: {
                        Text(stream.artist)
                    }
                    .listRowBackground(Theme.surface)
                } else if !query.isEmpty, LinkImport.kind(of: query) != nil {
                    Section {
                        Button { linkImport = query } label: {
                            Label("Открыть плейлист по ссылке", systemImage: "link")
                                .font(.headline)
                        }
                    } footer: {
                        Text("YouTube, YouTube Music, Spotify или ссылка hkotuner")
                    }
                    .listRowBackground(Theme.surface)
                } else if searched.isEmpty && !searching {
                    startPage
                } else {
                    results
                }
            }
            .listStyle(.plain)
            .screenBackground()
            .navigationTitle("Поиск")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Песня, исполнитель или ссылка")
            .onSubmit(of: .search) { run() }
            .onChange(of: scope) { _ in if !searched.isEmpty { run() } }
            .onChange(of: provider) { _ in if !searched.isEmpty { run() } }
            .onChange(of: query) { text in
                if text.isEmpty {
                    searchTask?.cancel()
                    searched = ""
                    songs = []
                    cards = []
                    error = nil
                    searching = false
                }
            }
            .sheet(item: Binding(get: { linkImport.map(LinkText.init) }, set: { linkImport = $0?.text })) { link in
                LinkImportView(link: link.text)
            }
        }
    }

    @ViewBuilder private var startPage: some View {
        if recent.isEmpty {
            EmptyNote(icon: "magnifyingglass", title: "Найди что угодно",
                      text: "Введи название песни или исполнителя.")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            Section {
                ForEach(recent, id: \.self) { text in
                    Button {
                        query = text
                        run()
                    } label: {
                        Label(text, systemImage: "clock.arrow.circlepath").foregroundStyle(Theme.ink)
                    }
                    .listRowBackground(Color.clear)
                }
                .onDelete { offsets in
                    var list = recent
                    list.remove(atOffsets: offsets)
                    recentRaw = list.joined(separator: "\n")
                }
            } header: {
                HStack {
                    Text("Недавние")
                    Spacer()
                    Button("Очистить") { recentRaw = "" }.font(.caption)
                }
            }
        }
    }

    /// the kinds of results, as the first row of the list (an inset at the
    /// top slid under the iOS 26 search field)
    private var scopePicker: some View {
        Picker("Что искать", selection: $scope) {
            ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder private var results: some View {
        if provider == .youtube { scopePicker }
        if searching {
            ProgressView().frame(maxWidth: .infinity).padding().listRowBackground(Color.clear)
        } else if let error {
            Text(error).foregroundStyle(Theme.muted).listRowBackground(Color.clear)
        } else if provider == .soundCloud || scope == .songs {
            if songs.isEmpty {
                EmptyNote(icon: "questionmark", title: "Ничего не нашлось").listRowBackground(Color.clear)
            }
            ForEach(songs) { track in
                TrackRow(track: track)
                    .onTapGesture { player.playSingle(track) }
                    .trackMenu(track)
            }
        } else {
            if cards.isEmpty {
                EmptyNote(icon: "questionmark", title: "Ничего не нашлось").listRowBackground(Color.clear)
            }
            ForEach(cards) { card in
                NavigationLink { CardDestination(card: card) } label: { CardRow(card: card) }
                    .listRowBackground(Color.clear)
            }
        }
    }

    private func run() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if let stream = Track.audioStream(from: q) {
            player.playSingle(stream)
            return
        }
        if LinkImport.kind(of: q) != nil {
            linkImport = q
            return
        }
        remember(q)
        searchTask?.cancel()
        searched = q
        searching = true
        error = nil
        let wanted = scope
        let service = provider
        searchTask = Task {
            defer { if !Task.isCancelled { searching = false } }
            do {
                if service == .soundCloud {
                    let found = try await EmbeddedAudioResolver.searchSoundCloud(q)
                    if !Task.isCancelled { songs = found }
                } else if wanted == .songs {
                    let found = try await YTMusic.search(q)
                    if !Task.isCancelled { songs = found }
                } else {
                    let found: [MusicCard]
                    switch wanted {
                    case .artists: found = try await YTMusic.searchArtists(q)
                    case .albums: found = try await YTMusic.searchAlbums(q)
                    case .playlists: found = try await YTMusic.searchPlaylists(q)
                    case .songs: return
                    }
                    if !Task.isCancelled { cards = found }
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func remember(_ text: String) {
        var list = recent.filter { $0.caseInsensitiveCompare(text) != .orderedSame }
        list.insert(text, at: 0)
        recentRaw = list.prefix(12).joined(separator: "\n")
    }
}

private struct LinkText: Identifiable {
    let text: String
    var id: String { text }
}

/// an artist, album or playlist found in search
struct CardRow: View {
    let card: MusicCard

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: card.thumbnailURL, size: 56, radius: card.kind == .artist ? 28 : 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.title).foregroundStyle(Theme.ink).lineLimit(1)
                Text(card.subtitle.isEmpty ? kindName : card.subtitle)
                    .font(.subheadline).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
    }

    private var kindName: String {
        switch card.kind {
        case .artist: return "Исполнитель"
        case .album: return "Альбом"
        case .playlist: return "Плейлист"
        }
    }
}

/// a pasted link to a playlist: read, matched, shown, kept
struct LinkImportView: View {
    @Environment(\.dismiss) private var dismiss
    let link: String
    @State private var shared: SharedPlaylist?
    @State private var progress: (Int, Int) = (0, 0)
    @State private var error: String?

    var body: some View {
        Group {
            if let shared {
                IncomingPlaylistView(shared: shared)
            } else {
                NavigationStack {
                    VStack(spacing: 16) {
                        if let error {
                            EmptyNote(icon: "exclamationmark.triangle", title: "Не получилось", text: error)
                        } else {
                            ProgressView()
                            Text(progressText).font(.subheadline).foregroundStyle(Theme.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ScreenBackground())
                    .navigationTitle("Плейлист по ссылке")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
                }
            }
        }
        .task {
            do {
                shared = try await LinkImport.load(link) { done, total in progress = (done, total) }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var progressText: String {
        let (done, total) = progress
        if total > 0 { return "Ищу песни в YouTube Music: \(done) из \(total)" }
        if done > 0 { return "Читаю плейлист: \(songsText(done))" }
        return "Читаю ссылку…"
    }
}

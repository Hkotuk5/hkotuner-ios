import SwiftUI

struct SearchView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case songs = "Песни", artists = "Исполнители", albums = "Альбомы", playlists = "Плейлисты"
        var id: String { rawValue }
    }

    @EnvironmentObject private var player: Player
    @State private var query = ""
    @State private var scope = Scope.songs
    @State private var songs: [Track] = []
    @State private var cards: [MusicCard] = []
    @State private var searching = false
    @State private var error: String?
    @State private var searched = ""
    @State private var linkImport: String?
    @AppStorage("recentSearches") private var recentRaw = ""

    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        NavigationStack {
            List {
                if !query.isEmpty, LinkImport.kind(of: query) != nil {
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
            .onChange(of: query) { text in
                if text.isEmpty {
                    searched = ""
                    songs = []
                    cards = []
                    error = nil
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !searched.isEmpty || searching {
                    Picker("Что искать", selection: $scope) {
                        ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
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
                      text: "Песни, исполнители, альбомы и плейлисты YouTube Music. Можно вставить ссылку на плейлист из YouTube или Spotify — он перенесётся сюда.")
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

    @ViewBuilder private var results: some View {
        if searching {
            ProgressView().frame(maxWidth: .infinity).padding().listRowBackground(Color.clear)
        } else if let error {
            Text(error).foregroundStyle(Theme.muted).listRowBackground(Color.clear)
        } else if scope == .songs {
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
        if LinkImport.kind(of: q) != nil {
            linkImport = q
            return
        }
        remember(q)
        searched = q
        searching = true
        error = nil
        let wanted = scope
        Task {
            do {
                switch wanted {
                case .songs: songs = try await YTMusic.search(q)
                case .artists: cards = try await YTMusic.searchArtists(q)
                case .albums: cards = try await YTMusic.searchAlbums(q)
                case .playlists: cards = try await YTMusic.searchPlaylists(q)
                }
            } catch {
                self.error = error.localizedDescription
            }
            if scope == wanted && searched == q { searching = false }
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

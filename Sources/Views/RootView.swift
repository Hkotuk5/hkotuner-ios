import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    @State private var showNowPlaying = false
    @State private var incoming: SharedPlaylist?
    @State private var pendingPairing: (key: String, address: String?)?
    @State private var confirmPairing = false
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            screen(HomeView(), "Главная", "house.fill", 0)
            screen(SearchView(), "Поиск", "magnifyingglass", 1)
            screen(LibraryView(), "Библиотека", "square.stack.fill", 2)
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
        .sheet(item: $incoming) { shared in
            IncomingPlaylistView(shared: shared)
        }
        .overlay(alignment: .top) { Toast() }
        .onOpenURL(perform: open)
        .confirmationDialog("Подключить этот компьютер?", isPresented: $confirmPairing, titleVisibility: .visible) {
            Button("Подключить") {
                guard let pairing = pendingPairing else { return }
                defer { pendingPairing = nil }
                do {
                    let sync = DeviceSync.shared
                    try sync.pair(pairing.key, address: pairing.address)
                    Task {
                        let before = sync.lastSync
                        await sync.sync()
                        if sync.lastSync != before {
                            player.message = "Компьютер синхронизирован"
                        } else if let error = sync.error {
                            player.message = error
                        }
                    }
                } catch { player.message = error.localizedDescription }
            }
            Button("Отмена", role: .cancel) { pendingPairing = nil }
        } message: {
            Text("hkotuner будет обмениваться песнями, плейлистами, профилем и годовыми итогами в общей сети Wi-Fi.")
        }
    }

    private func screen<V: View>(_ content: V, _ title: String, _ icon: String, _ tag: Int) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if player.current != nil {
                    MiniPlayer { showNowPlaying = true }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
            }
            .tabItem { Label(title, systemImage: icon) }
            .tag(tag)
    }

    /// a shared playlist: an hkotuner:// link from the share page, or a .hkplaylist file
    private func open(_ url: URL) {
        if url.scheme?.lowercased() == "hkotuner", url.host == "pair",
           let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let key = fields.first(where: { $0.name == "key" })?.value {
            pendingPairing = (key, fields.first(where: { $0.name == "address" })?.value)
            confirmPairing = true
            return
        }
        if url.isFileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                player.message = "Не удалось открыть файл"
                return
            }
            if let shared = try? ShareCodec.readFile(data) {
                incoming = shared
            } else if let added = try? library.importDesktop(data) {
                player.message = "Добавлено с компьютера: \(added.liked) любимых, \(added.playlists) плейлистов"
            } else {
                player.message = "Это не плейлист hkotuner"
            }
            return
        }
        do {
            incoming = try ShareCodec.readLink(url.absoluteString)
        } catch {
            player.message = error.localizedDescription
        }
    }
}

/// a message from the player at the top of the screen, gone after a while
struct Toast: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        if let message = player.message {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.accent)
                Text(message).font(.footnote).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                Button { player.message = nil } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Theme.muted)
                }
                .accessibilityLabel("Закрыть")
            }
            .padding(14)
            .glassCard(radius: 18)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: message) {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                if player.message == message { withAnimation { player.message = nil } }
            }
        }
    }
}

/// the song that plays, floating over the bottom of every screen
struct MiniPlayer: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    let open: () -> Void

    var body: some View {
        if let track = player.current {
            HStack(spacing: 12) {
                Artwork(url: track.thumbnailURL, size: 44, radius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(track.artist).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 6)
                Button { library.toggleLike(track) } label: {
                    Image(systemName: library.isLiked(track) ? "heart.fill" : "heart")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(library.isLiked(track) ? Theme.accent : Theme.ink)
                        .frame(width: 38, height: 44)
                }
                .accessibilityLabel(library.isLiked(track) ? "Убрать из любимых" : "В любимые")
                Button { player.toggle() } label: {
                    Group {
                        if player.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        }
                    }
                    .font(.title3)
                    .foregroundStyle(Theme.ink)
                    .frame(width: 40, height: 44)
                }
                .accessibilityLabel(player.isPlaying ? "Пауза" : "Играть")
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.body).foregroundStyle(Theme.ink).frame(width: 36, height: 44)
                }
                .accessibilityLabel("Следующий")
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: player.length > 0 ? geo.size.width * min(1, player.position / player.length) : 0, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 18)
            }
            .glassCard(radius: 20)
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
        }
    }
}

/// a playlist someone sent: what is in it, and keeping or playing it
struct IncomingPlaylistView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let shared: SharedPlaylist
    @State private var kept = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(shared.name).font(.title2.weight(.bold)).foregroundStyle(Theme.ink)
                        Text(songsText(shared.tracks.count) + (shared.missing.isEmpty ? "" : " · не нашлось \(shared.missing.count)"))
                            .font(.subheadline).foregroundStyle(Theme.muted)
                        PlayButtons(tracks: shared.tracks)
                        Button {
                            library.keep(shared)
                            kept = true
                        } label: {
                            Label(kept ? "Сохранён в библиотеке" : "Сохранить себе", systemImage: kept ? "checkmark" : "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(kept)
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(Array(shared.tracks.enumerated()), id: \.element.id) { i, track in
                        TrackRow(track: track)
                            .onTapGesture { player.play(shared.tracks, at: i) }
                            .trackMenu(track)
                    }
                }
                if !shared.missing.isEmpty {
                    Section("Не нашлись в YouTube Music") {
                        ForEach(shared.missing, id: \.self) { Text($0).font(.footnote).foregroundStyle(Theme.muted) }
                    }
                }
            }
            .screenBackground()
            .navigationTitle("Плейлист")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
}

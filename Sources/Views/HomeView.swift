import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var account: YTAccount
    @StateObject private var feed = HomeFeed.shared
    @StateObject private var releases = NewReleases.shared
    @ObservedObject private var sync = DeviceSync.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    WaveCard()
                        .padding(.horizontal, 16)
                    SmartRow()
                    if !releases.items.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(title: "Новое у ваших исполнителей")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(releases.items) { release in
                                        NavigationLink { CardDestination(card: release.card) } label: {
                                            CardTile(card: MusicCard(id: release.card.id, kind: release.card.kind, title: release.card.title,
                                                                     subtitle: release.artist, thumbnail: release.card.thumbnail))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                    TrackShelf(title: "Недавно слушали", tracks: library.library.history,
                               more: AnyView(HistoryView()))
                    TrackShelf(title: "Любимые", tracks: library.library.liked,
                               more: AnyView(LikedView()))
                    ForEach(feed.shelves) { shelf in
                        TrackShelf(title: shelf.title, tracks: shelf.tracks)
                        CardShelf(title: shelf.tracks.isEmpty ? shelf.title : "", cards: shelf.cards)
                    }
                    if feed.loading && feed.shelves.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else if let error = feed.error, feed.shelves.isEmpty {
                        VStack(spacing: 8) {
                            Text("Подборки YouTube Music не загрузились").font(.subheadline.weight(.semibold))
                            Text(error).font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                            Button("Ещё раз") { Task { await feed.load(force: true) } }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .refreshable {
                await feed.load(force: true)
                await releases.load(library.library.artists)
            }
            .background(ScreenBackground())
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await feed.load()
                await releases.load(library.library.artists)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            NavigationLink { SettingsView() } label: {
                ListenerAvatar(profile: sync.profile, fallback: initial, size: 44)
            }
            .accessibilityLabel("Настройки и профиль")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var name: String {
        let own = sync.profile?.name.trimmingCharacters(in: .whitespaces) ?? ""
        if !own.isEmpty { return own }
        return account.name?.split(separator: " ").first.map(String.init) ?? ""
    }

    private var initial: String {
        name.first.map { String($0).uppercased() } ?? "♪"
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part: String
        switch hour {
        case 5..<12: part = "Доброе утро"
        case 12..<18: part = "Добрый день"
        case 18..<23: part = "Добрый вечер"
        default: part = "Доброй ночи"
        }
        return name.isEmpty ? part : "\(part), \(name)"
    }

    private var subtitle: String {
        let today = StatsStore.shared.seconds(lastDays: 1)
        if today >= 60 { return "Сегодня уже \(listenedText(today)) музыки" }
        return account.isSignedIn ? "Подборки из твоего YouTube Music" : "Что включим?"
    }
}

/// «Моя волна»: one big button that never runs out of songs
struct WaveCard: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore

    private var playing: Bool { player.isWave && player.isPlaying }
    private var loading: Bool { player.isWave && player.isLoading }

    var body: some View {
        Button {
            if player.isWave && player.current != nil { player.toggle() }
            else { player.startWave() }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Моя волна")
                        .font(.title2.weight(.bold))
                    if player.isWave, let current = player.current {
                        Text("\(current.artist) — \(current.title)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.74))
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        ZStack {
                            Circle().fill(.white)
                            if loading {
                                ProgressView().tint(.black)
                            } else {
                                Image(systemName: playing ? "pause.fill" : "play.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.black)
                            }
                        }
                        .frame(width: 52, height: 52)
                        Circle().fill(Color(red: 0.65, green: 0.48, blue: 1)).frame(width: 5, height: 5)
                        Text(loading ? "Подбираю…" : playing ? "Волна играет" : "Слушать")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.74))
                    }
                    .padding(.top, 7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                covers
            }
            .foregroundStyle(.white)
            .padding(18)
            .frame(minHeight: 164)
            .background {
                let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
                shape.fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .overlay {
                        shape.fill(LinearGradient(colors: [.black.opacity(0.33), Color(red: 0.25, green: 0.13, blue: 0.23).opacity(0.33)],
                                                  startPoint: .leading, endPoint: .trailing))
                    }
                    .overlay { shape.strokeBorder(.white.opacity(0.12)) }
            }
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .accessibilityHint(playing ? "Поставить волну на паузу" : "Включить волну")
    }

    private var covers: some View {
        let tracks = (player.isWave ? Array(player.queue.dropFirst(max(0, player.index)).prefix(4)) : [])
            + Array(library.library.liked.prefix(8)) + Array(library.library.history.prefix(8))
        var seen = Set<URL>()
        let images = Array(tracks.compactMap(\.thumbnailURL).filter { seen.insert($0).inserted }.prefix(4))
        return ZStack(alignment: .leading) {
            ForEach(0..<4, id: \.self) { index in
                Artwork(url: images.indices.contains(index) ? images[index] : nil, size: 64, radius: 6)
                    .rotationEffect(.degrees(Double(index - 2) * 4))
                    .offset(x: CGFloat(index) * 13)
                    .shadow(color: .black.opacity(0.36), radius: 4, y: 3)
            }
        }
        .frame(width: 108, height: 80, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// the playlists the app fills by itself, as chips under the wave
struct SmartRow: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var stats = StatsStore.shared

    var body: some View {
        let hidden = Set(library.library.disliked.map(\.id))
        let frequent = stats.frequent(hidden: hidden)
        let forgotten = stats.forgotten(liked: library.library.liked, hidden: hidden)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if frequent.count >= 5 {
                    chip("Часто слушаю", "flame.fill") { SmartPlaylistView(title: "Часто слушаю", tracks: frequent) }
                }
                if forgotten.count >= 5 {
                    chip("Давно не слышал", "clock.arrow.circlepath") { SmartPlaylistView(title: "Давно не слышал", tracks: forgotten) }
                }
                if !library.library.local.isEmpty {
                    chip("Мои файлы", "folder.fill") { LocalFilesView() }
                }
                chip("Статистика", "chart.bar.fill") { StatsView() }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip<D: View>(_ title: String, _ icon: String, @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink(destination: destination) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(Theme.surface))
        }
        .buttonStyle(.plain)
    }
}

struct SmartPlaylistView: View {
    @EnvironmentObject private var library: LibraryStore
    let title: String
    let tracks: [Track]
    @State private var saved = false

    var body: some View {
        TrackListView(title: title, tracks: tracks)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(saved ? "Сохранён" : "Сохранить") {
                        library.createPlaylist(title, tracks: tracks)
                        saved = true
                    }
                    .disabled(saved)
                }
            }
    }
}

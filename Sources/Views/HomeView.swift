import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var account: YTAccount
    @StateObject private var feed = HomeFeed.shared
    @StateObject private var releases = NewReleases.shared
    @AppStorage("profile.name") private var profileName = ""

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
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.18))
                    Text(initial).font(.headline.weight(.bold)).foregroundStyle(Theme.accent)
                }
                .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Настройки и профиль")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var name: String {
        let own = profileName.trimmingCharacters(in: .whitespaces)
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
    @State private var phase = false

    var body: some View {
        Button { player.startWave() } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.55), Color(red: 0.55, green: 0.22, blue: 0.12)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                bars
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(20)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Моя волна").font(.title.weight(.heavy)).foregroundStyle(.black)
                    Text(player.isWave ? "Играет — нажми, чтобы начать заново" : "Бесконечный поток по твоему вкусу")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.black.opacity(0.7))
                    HStack(spacing: 6) {
                        Image(systemName: player.isWave && player.isLoading ? "hourglass" : "play.fill")
                        Text(player.isWave && player.isLoading ? "Подбираю…" : "Слушать")
                    }
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.black))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 6)
                }
                .padding(20)
            }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .onAppear { phase = true }
    }

    private var bars: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(.black.opacity(0.75))
                    .frame(width: 6, height: phase && player.isWave && player.isPlaying ? CGFloat([34, 52, 26, 44, 30][i]) : CGFloat([14, 22, 10, 18, 12][i]))
                    .animation(.easeInOut(duration: 0.55 + Double(i) * 0.08).repeatForever(autoreverses: true), value: phase && player.isPlaying)
            }
        }
        .frame(height: 56, alignment: .bottom)
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

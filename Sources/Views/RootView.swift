import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: Player
    @State private var showNowPlaying = false

    var body: some View {
        TabView {
            tab(HomeView(), "Главная", "house.fill")
            tab(SearchView(), "Поиск", "magnifyingglass")
            tab(LibraryView(), "Библиотека", "music.note.list")
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
    }

    private func tab<V: View>(_ content: V, _ title: String, _ icon: String) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if player.current != nil {
                    MiniPlayer { showNowPlaying = true }
                }
            }
            .tabItem { Label(title, systemImage: icon) }
    }
}

/// a cover from the internet, or a quiet note sign while there is none
struct Artwork: View {
    let url: URL?
    var size: CGFloat = 48
    var radius: CGFloat = 6

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius).fill(Theme.surface)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        note
                    }
                }
            } else {
                note
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }

    private var note: some View {
        Image(systemName: "music.note")
            .font(.system(size: size * 0.38))
            .foregroundStyle(Theme.muted)
    }
}

/// a line under the screen while something plays
struct MiniPlayer: View {
    @EnvironmentObject private var player: Player
    let open: () -> Void

    var body: some View {
        if let track = player.current {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: player.length > 0 ? geo.size.width * min(1, player.position / player.length) : 0)
                }
                .frame(height: 2)
                HStack(spacing: 12) {
                    Artwork(url: track.thumbnailURL, size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(track.artist).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button { player.toggle() } label: {
                        Group {
                            if player.isLoading {
                                ProgressView()
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            }
                        }
                        .font(.title3)
                        .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(player.isPlaying ? "Пауза" : "Играть")
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill").font(.title3).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Следующий")
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(.ultraThinMaterial)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
        }
    }
}

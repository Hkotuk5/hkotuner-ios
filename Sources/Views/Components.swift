import SwiftUI
import UIKit

/// a cover from the internet, or a quiet note sign while there is none;
/// `size: nil` fills the width as a square
struct Artwork: View {
    let url: URL?
    var size: CGFloat? = 48
    var radius: CGFloat = 8

    var body: some View {
        Theme.surface
            .overlay { picture }
            .frame(width: size, height: size)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    @ViewBuilder private var picture: some View {
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

    private var note: some View {
        Image(systemName: "music.note")
            .font(.system(size: (size ?? 140) * 0.34, weight: .medium))
            .foregroundStyle(Theme.muted)
    }
}

/// a playlist's own picture, else four of its covers, else its first one
struct PlaylistCover: View {
    @EnvironmentObject private var library: LibraryStore
    let playlist: Playlist
    var size: CGFloat? = 56
    var radius: CGFloat = 10

    var body: some View {
        Theme.surface
            .overlay { content }
            .frame(width: size, height: size)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .id(library.coverVersion)
    }

    private var covers: [URL] {
        var seen = Set<String>()
        return playlist.tracks.compactMap { $0.thumbnailURL }.filter { seen.insert($0.absoluteString).inserted }
    }

    @ViewBuilder private var content: some View {
        if let file = library.coverURL(playlist.id), let image = UIImage(contentsOfFile: file.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if covers.count >= 4 {
            GeometryReader { geo in
                let half = geo.size.width / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) { tile(covers[0], half); tile(covers[1], half) }
                    HStack(spacing: 0) { tile(covers[2], half); tile(covers[3], half) }
                }
            }
        } else if let first = covers.first {
            Artwork(url: first, size: nil, radius: 0)
        } else {
            LinearGradient(colors: [Theme.accent.opacity(0.55), Theme.accent.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    Image(systemName: "music.note.list")
                        .font(.system(size: (size ?? 140) * 0.34, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
        }
    }

    private func tile(_ url: URL, _ side: CGFloat) -> some View {
        Artwork(url: url, size: side, radius: 0)
    }
}

/// an album, playlist or artist on a shelf
struct CardTile: View {
    let card: MusicCard
    var width: CGFloat = 148

    var body: some View {
        VStack(alignment: card.kind == .artist ? .center : .leading, spacing: 6) {
            if card.kind == .artist {
                Artwork(url: card.thumbnailURL, size: width, radius: width / 2)
            } else {
                Artwork(url: card.thumbnailURL, size: width, radius: 12)
            }
            Text(card.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            if !card.subtitle.isEmpty {
                Text(card.subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
        .frame(width: width)
    }
}

/// a song on a shelf: a big cover, its name under it
struct TrackTile: View {
    @EnvironmentObject private var player: Player
    let track: Track
    var width: CGFloat = 148

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: track.thumbnailURL, size: width, radius: 12)
                .overlay(alignment: .bottomTrailing) {
                    if player.current?.id == track.id {
                        Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(7)
                            .background(Circle().fill(Theme.accent))
                            .padding(8)
                    }
                }
            Text(track.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Text(track.artist)
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .frame(width: width)
    }
}

/// where a card leads
struct CardDestination: View {
    let card: MusicCard

    var body: some View {
        switch card.kind {
        case .artist: ArtistView(artistId: card.id, name: card.title)
        case .album: AlbumView(browseId: card.id, kind: .album, fallbackTitle: card.title)
        case .playlist: AlbumView(browseId: card.id, kind: .playlist, fallbackTitle: card.title)
        }
    }
}

/// a horizontal row of cards with a title
struct CardShelf: View {
    let title: String
    let cards: [MusicCard]

    var body: some View {
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: title)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(cards) { card in
                            NavigationLink { CardDestination(card: card) } label: { CardTile(card: card) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }
}

/// a horizontal row of songs with a title; a tap plays the row from that song
struct TrackShelf: View {
    @EnvironmentObject private var player: Player
    let title: String
    let tracks: [Track]
    var more: AnyView? = nil

    var body: some View {
        if !tracks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: title, more: more)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(Array(tracks.prefix(20).enumerated()), id: \.element.id) { i, track in
                            Button { player.play(Array(tracks.prefix(20)), at: i) } label: { TrackTile(track: track) }
                                .buttonStyle(.plain)
                                .trackMenu(track)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }
}

struct SectionTitle: View {
    let title: String
    var more: AnyView? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.bold)).foregroundStyle(Theme.ink)
            Spacer()
            if let more {
                NavigationLink { more } label: {
                    Text("Все").font(.subheadline.weight(.semibold))
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

/// «Слушать» and «Вперемешку» side by side
struct PlayButtons: View {
    @EnvironmentObject private var player: Player
    let tracks: [Track]

    var body: some View {
        HStack(spacing: 12) {
            Button { player.play(tracks) } label: {
                Label("Слушать", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(Theme.accent))
                    .foregroundStyle(.black)
            }
            Button { player.shuffle(tracks) } label: {
                Label("Вперемешку", systemImage: "shuffle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(Theme.surface))
                    .foregroundStyle(Theme.ink)
            }
        }
        .buttonStyle(.plain)
        .disabled(tracks.isEmpty)
        .opacity(tracks.isEmpty ? 0.5 : 1)
    }
}

struct EmptyNote: View {
    let icon: String
    let title: String
    var text: String = ""

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(title).font(.headline).foregroundStyle(Theme.ink)
            if !text.isEmpty {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
    }
}

/// the warm glow at the top of every screen
struct ScreenBackground: View {
    @ObservedObject private var wallpaper = WallpaperStore.shared

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background
            RadialGradient(colors: [Theme.accent.opacity(0.16), .clear], center: .top, startRadius: 0, endRadius: 420)
                .frame(height: 420)
            if let bytes = wallpaper.image { WallpaperImage(bytes: bytes, aspect: wallpaper.aspect, crop: wallpaper.crop) }
        }
        .ignoresSafeArea()
    }
}

extension View {
    func screenBackground() -> some View {
        scrollContentBackground(.hidden).background(ScreenBackground())
    }

    /// iOS 26 glass where there is one, a material elsewhere
    @ViewBuilder
    func glassCard(radius: CGFloat = 22) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        #else
        self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        #endif
    }
}

/// "1 ч 20 мин", "12 мин"
func listenedText(_ seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    if minutes >= 60 { return "\(minutes / 60) ч \(minutes % 60) мин" }
    return "\(minutes) мин"
}

/// "1 песня", "3 песни", "12 песен"
func songsText(_ n: Int) -> String {
    let last = n % 10
    let lastTwo = n % 100
    let word: String
    if last == 1 && lastTwo != 11 {
        word = "песня"
    } else if (2...4).contains(last) && !(12...14).contains(lastTwo) {
        word = "песни"
    } else {
        word = "песен"
    }
    return "\(n) \(word)"
}

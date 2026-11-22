import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var scrub: Double?
    @State private var picking = false
    @State private var showQueue = false

    var body: some View {
        ZStack {
            background
            if let track = player.current {
                VStack(spacing: 20) {
                    Capsule().fill(Theme.muted).frame(width: 40, height: 5).padding(.top, 8)
                    if showQueue {
                        queueList
                    } else {
                        Spacer(minLength: 0)
                        Artwork(url: track.thumbnailURL, size: 300, radius: 14)
                            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                        Spacer(minLength: 0)
                    }
                    titleRow(track)
                    progress
                    controls
                    actions(track)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            } else {
                Text("Ничего не играет").foregroundStyle(Theme.muted)
            }
        }
        .sheet(isPresented: $picking) {
            if let track = player.current { PlaylistPicker(tracks: [track]) }
        }
    }

    private var background: some View {
        ZStack {
            Theme.background
            if let url = player.current?.thumbnailURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
                .blur(radius: 60)
                .opacity(0.45)
            }
        }
        .ignoresSafeArea()
    }

    private func titleRow(_ track: Track) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.title3.weight(.bold)).lineLimit(2)
                Text(track.artist).font(.body).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            Button { library.toggleLike(track) } label: {
                Image(systemName: library.isLiked(track) ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundStyle(library.isLiked(track) ? Theme.accent : Theme.ink)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(library.isLiked(track) ? "Убрать из любимых" : "В любимые")
        }
    }

    private var progress: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrub ?? player.position },
                    set: { scrub = $0 }
                ),
                in: 0...max(player.length, 1),
                onEditingChanged: { editing in
                    if !editing, let value = scrub {
                        player.seek(to: value)
                        scrub = nil
                    }
                }
            )
            HStack {
                Text(Track.clock(scrub ?? player.position))
                Spacer()
                if player.isLoading { ProgressView().scaleEffect(0.7) }
                Spacer()
                Text(Track.clock(player.length))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.muted)
        }
    }

    private var controls: some View {
        HStack {
            Button { player.repeatOne.toggle() } label: {
                Image(systemName: "repeat.1")
                    .foregroundStyle(player.repeatOne ? Theme.accent : Theme.muted)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Повтор трека")
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title).frame(width: 56, height: 56)
            }
            .accessibilityLabel("Предыдущий")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(Theme.ink)
            }
            .accessibilityLabel(player.isPlaying ? "Пауза" : "Играть")
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title).frame(width: 56, height: 56)
            }
            .accessibilityLabel("Следующий")
            Spacer()
            Button { player.autoContinue.toggle() } label: {
                Image(systemName: "infinity")
                    .foregroundStyle(player.autoContinue ? Theme.accent : Theme.muted)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Похожие после очереди")
        }
        .foregroundStyle(Theme.ink)
    }

    private func actions(_ track: Track) -> some View {
        HStack {
            Button { picking = true } label: {
                Label("В плейлист", systemImage: "text.badge.plus")
            }
            Spacer()
            if track.isYouTube {
                Button { library.toggleDislike(track); if library.isDisliked(track) { player.next() } } label: {
                    Image(systemName: library.isDisliked(track) ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }
                .accessibilityLabel("Не нравится")
                Spacer()
            }
            Button { withAnimation { showQueue.toggle() } } label: {
                Label("Очередь", systemImage: showQueue ? "photo" : "list.bullet")
            }
        }
        .font(.subheadline)
        .foregroundStyle(Theme.muted)
        .labelStyle(.titleAndIcon)
    }

    private var queueList: some View {
        List {
            if let message = player.message {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
            Section(player.isWave ? "Моя волна — дальше" : "Дальше") {
                ForEach(Array(player.upcoming.enumerated()), id: \.element.id) { offset, track in
                    TrackRow(track: track)
                        .onTapGesture { player.jump(to: player.index + 1 + offset) }
                        .trackMenu(track)
                }
                .onDelete { player.removeUpcoming(at: $0) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

import SwiftUI

struct TrackRow: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    let track: Track

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: track.thumbnailURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.body)
                    .foregroundStyle(player.current?.id == track.id ? Theme.accent : Theme.ink)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let id = track.videoId, AudioCache.isOffline(id) {
                        Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(Theme.accent)
                    }
                    Text(subtitle).font(.subheadline).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if library.isLiked(track) {
                Image(systemName: "heart.fill").font(.caption).foregroundStyle(Theme.accent)
            }
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        [track.artist, track.durationText].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// what a long press on a song offers everywhere
struct TrackMenu: ViewModifier {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    let track: Track
    @State private var picking = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button { player.playNext(track) } label: { Label("Играть следующим", systemImage: "text.insert") }
                Button { player.addToQueue([track]) } label: { Label("В конец очереди", systemImage: "text.append") }
                Button { library.toggleLike(track) } label: {
                    library.isLiked(track)
                        ? Label("Убрать из любимых", systemImage: "heart.slash")
                        : Label("В любимые", systemImage: "heart")
                }
                Button { picking = true } label: { Label("В плейлист…", systemImage: "text.badge.plus") }
                if track.isYouTube {
                    Button { player.playSingle(track) } label: {
                        Label("Похожие треки", systemImage: "dot.radiowaves.left.and.right")
                    }
                    Button(role: library.isDisliked(track) ? nil : .destructive) { library.toggleDislike(track) } label: {
                        library.isDisliked(track)
                            ? Label("Вернуть в рекомендации", systemImage: "hand.thumbsup")
                            : Label("Не нравится", systemImage: "hand.thumbsdown")
                    }
                }
            }
            .sheet(isPresented: $picking) {
                PlaylistPicker(tracks: [track])
            }
    }
}

extension View {
    func trackMenu(_ track: Track) -> some View { modifier(TrackMenu(track: track)) }
}

/// "add to playlist": the playlists, and a new one
struct PlaylistPicker: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let tracks: [Track]
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Button { naming = true } label: { Label("Новый плейлист", systemImage: "plus") }
                ForEach(library.library.playlists) { playlist in
                    Button {
                        library.add(tracks, to: playlist.id)
                        dismiss()
                    } label: {
                        HStack {
                            Artwork(url: playlist.tracks.first?.thumbnailURL, size: 40)
                            VStack(alignment: .leading) {
                                Text(playlist.name).foregroundStyle(Theme.ink)
                                Text("\(playlist.tracks.count) треков").font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
            }
            .navigationTitle("В плейлист")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
            .alert("Новый плейлист", isPresented: $naming) {
                TextField("Название", text: $name)
                Button("Создать") {
                    library.createPlaylist(name, tracks: tracks)
                    name = ""
                    dismiss()
                }
                Button("Отмена", role: .cancel) { name = "" }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

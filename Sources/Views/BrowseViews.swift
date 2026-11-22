import SwiftUI

/// An artist's page: popular songs, albums, singles, similar artists, follow.
struct ArtistView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    /// nil: found by name first
    let artistId: String?
    let name: String
    @State private var page: ArtistPage?
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let page {
                content(page)
            } else if let error {
                EmptyNote(icon: "music.mic", title: name, text: error)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
            }
        }
        .background(ScreenBackground())
        .navigationTitle(page?.name ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard page == nil else { return }
        do {
            var id = artistId
            if id == nil {
                guard let found = try await YTMusic.findArtist(name) else { throw HKError("Не нашёл исполнителя в YouTube Music") }
                id = found.id
            }
            page = try await YTMusic.artist(id!)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func content(_ page: ArtistPage) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            header(page)
            if !page.songs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionTitle(title: "Популярное", more: page.songsId.map {
                        AnyView(AlbumView(browseId: $0, kind: .playlist, fallbackTitle: "Все песни: \(page.name)"))
                    })
                    ForEach(Array(page.songs.prefix(5).enumerated()), id: \.element.id) { i, track in
                        TrackRow(track: track)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                            .onTapGesture { player.play(page.songs, at: i) }
                            .trackMenu(track)
                    }
                }
            }
            CardShelf(title: "Альбомы", cards: page.albums)
            CardShelf(title: "Синглы", cards: page.singles)
            CardShelf(title: "Похожие исполнители", cards: page.similar)
            if let about = page.description {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(title: "Об исполнителе")
                    Text(about)
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(8)
                        .padding(.horizontal, 16)
                }
            }
        }
        .padding(.bottom, 24)
    }

    private func header(_ page: ArtistPage) -> some View {
        VStack(spacing: 14) {
            Artwork(url: page.thumbnail.flatMap(URL.init(string:)), size: 190, radius: 95)
                .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
            Text(page.name).font(.largeTitle.weight(.bold)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
            if let audience = page.audience {
                Text(audience).font(.subheadline).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 12) {
                let followed = library.isFollowed(page.id)
                Button {
                    library.toggleFollow(FollowedArtist(id: page.id, name: page.name, thumbnail: page.thumbnail))
                } label: {
                    Label(followed ? "Вы подписаны" : "Подписаться", systemImage: followed ? "checkmark" : "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().stroke(Theme.muted, lineWidth: 1))
                        .foregroundStyle(Theme.ink)
                }
                if let seed = page.songs.first {
                    Button { player.playSingle(seed) } label: {
                        Label("Радио", systemImage: "dot.radiowaves.left.and.right")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Theme.accent))
                            .foregroundStyle(.black)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.horizontal, 16)
    }
}

/// An album, or a playlist from YouTube Music: its songs, play, keep, share.
struct AlbumView: View {
    enum Kind { case album, playlist }

    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    let browseId: String
    let kind: Kind
    var fallbackTitle = ""
    @State private var page: AlbumPage?
    @State private var error: String?
    @State private var loadingMore = false
    @State private var saved = false

    var body: some View {
        List {
            if let page {
                header(page)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                ForEach(Array(page.tracks.enumerated()), id: \.element.id) { i, track in
                    TrackRow(track: track, number: kind == .album ? i + 1 : nil)
                        .onTapGesture { player.play(page.tracks, at: i) }
                        .trackMenu(track)
                }
                if page.more != nil {
                    HStack {
                        Spacer()
                        if loadingMore { ProgressView() } else { Button("Загрузить ещё") { Task { await more() } } }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .onAppear { Task { await more() } }
                }
                if kind == .album, !page.subtitle.isEmpty {
                    Text(page.subtitle).font(.footnote).foregroundStyle(Theme.muted).listRowBackground(Color.clear)
                }
            } else if let error {
                EmptyNote(icon: "opticaldisc", title: fallbackTitle, text: error).listRowBackground(Color.clear)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 120).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .screenBackground()
        .navigationTitle(page?.title ?? fallbackTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let page, !page.tracks.isEmpty, let link = URL(string: ShareCodec.makeLink(name: page.title, tracks: page.tracks)) {
                    ShareLink(item: link) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Поделиться")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard page == nil else { return }
        do {
            if kind == .album {
                page = try await YTMusic.album(browseId)
            } else {
                page = try await YTMusic.playlist(browseId)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func more() async {
        guard !loadingMore, let token = page?.more else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let part = try? await YTMusic.playlistMore(token) else {
            page?.more = nil
            return
        }
        let known = Set(page?.tracks.map(\.id) ?? [])
        let fresh = part.tracks.filter { !known.contains($0.id) }
        page?.tracks += fresh
        page?.more = fresh.isEmpty ? nil : part.more
    }

    private func header(_ page: AlbumPage) -> some View {
        VStack(spacing: 14) {
            Artwork(url: page.thumbnail.flatMap(URL.init(string:)), size: 230, radius: 16)
                .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
            VStack(spacing: 4) {
                Text(page.title).font(.title2.weight(.bold)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                if !page.artist.isEmpty {
                    if let id = page.artistId {
                        NavigationLink { ArtistView(artistId: id, name: page.artist) } label: {
                            Text(page.artist).font(.headline).foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(page.artist).font(.headline).foregroundStyle(Theme.muted)
                    }
                }
                Text(info(page)).font(.caption).foregroundStyle(Theme.muted)
            }
            PlayButtons(tracks: page.tracks)
            Button {
                library.createPlaylist(page.title, tracks: page.tracks)
                saved = true
            } label: {
                Label(saved ? "Сохранено в библиотеке" : "Сохранить как плейлист", systemImage: saved ? "checkmark" : "plus")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(saved || page.tracks.isEmpty)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func info(_ page: AlbumPage) -> String {
        let total = page.tracks.compactMap(\.duration).reduce(0, +)
        var parts = [kind == .album ? "Альбом" : "Плейлист", songsText(page.tracks.count)]
        if total > 0 { parts.append(listenedText(total)) }
        return parts.joined(separator: " · ")
    }
}

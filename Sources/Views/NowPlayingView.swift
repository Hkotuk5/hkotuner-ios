import SwiftUI

struct NowPlayingView: View {
    enum Pane { case cover, lyrics, queue }

    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var audio = AudioSettings.shared
    @State private var scrub: Double?
    @State private var picking = false
    @State private var pane = Pane.cover
    @State private var showEqualizer = false
    @State private var showArtist = false

    var body: some View {
        ZStack {
            background
            if let track = player.current {
                VStack(spacing: 18) {
                    Capsule().fill(Theme.muted).frame(width: 40, height: 5).padding(.top, 8)
                    switch pane {
                    case .cover:
                        Spacer(minLength: 0)
                        Artwork(url: track.thumbnailURL, size: nil, radius: 18)
                            .frame(maxWidth: 340)
                            .scaleEffect(player.isPlaying ? 1 : 0.9)
                            .animation(.spring(response: 0.45, dampingFraction: 0.75), value: player.isPlaying)
                            .shadow(color: .black.opacity(0.5), radius: 28, y: 14)
                            .padding(.horizontal, 8)
                        Spacer(minLength: 0)
                    case .lyrics:
                        LyricsPane(track: track)
                    case .queue:
                        QueuePane()
                    }
                    titleRow(track)
                    progress
                    controls
                    bottomBar(track)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            } else {
                EmptyNote(icon: "music.note", title: "Ничего не играет")
            }
        }
        .sheet(isPresented: $picking) {
            if let track = player.current { PlaylistPicker(tracks: [track]) }
        }
        .sheet(isPresented: $showEqualizer) {
            NavigationStack {
                EqualizerView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showEqualizer = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showArtist) {
            if let track = player.current {
                NavigationStack {
                    ArtistView(artistId: track.artistId, name: LyricsService.mainArtist(track.artist))
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { showArtist = false } } }
                }
            }
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
                .blur(radius: 70)
                .opacity(0.55)
                .scaleEffect(1.3)
            }
            LinearGradient(colors: [.clear, Theme.background.opacity(0.85)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private func titleRow(_ track: Track) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Button { if track.isYouTube { showArtist = true } } label: {
                    Text(track.artist)
                        .font(.body)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
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
                    if !editing, let target = scrub {
                        player.seek(to: target)
                        scrub = nil
                    }
                }
            )
            HStack {
                Text(Track.clock(scrub ?? player.position))
                Spacer()
                if !player.throughEngine && player.current?.isYouTube == true && !player.isLoading {
                    Text("поток").font(.caption2.weight(.semibold)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Text("-" + Track.clock(max(0, player.length - (scrub ?? player.position))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.muted)
        }
    }

    private var controls: some View {
        HStack {
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? Theme.muted : Theme.accent)
            }
            .accessibilityLabel(repeatLabel)
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                .accessibilityLabel("Предыдущий")
            Spacer()
            Button { player.toggle() } label: {
                ZStack {
                    Circle().fill(Theme.accent).frame(width: 76, height: 76)
                    if player.isLoading {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.black)
                            .offset(x: player.isPlaying ? 0 : 2)
                    }
                }
            }
            .accessibilityLabel(player.isPlaying ? "Пауза" : "Играть")
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
                .accessibilityLabel("Следующий")
            Spacer()
            Button { player.autoContinue.toggle() } label: {
                Image(systemName: "infinity")
                    .foregroundStyle(player.autoContinue ? Theme.accent : Theme.muted)
            }
            .accessibilityLabel(player.autoContinue ? "Похожие после очереди: включено" : "Похожие после очереди: выключено")
        }
        .font(.title3)
        .foregroundStyle(Theme.ink)
        .buttonStyle(.plain)
    }

    private var repeatLabel: String {
        switch player.repeatMode {
        case .off: return "Повтор выключен"
        case .all: return "Повтор очереди"
        case .one: return "Повтор песни"
        }
    }

    private func bottomBar(_ track: Track) -> some View {
        HStack {
            paneButton(.lyrics, "quote.bubble", "Текст")
            Spacer()
            Menu {
                if player.sleepAt != nil || player.sleepAfterTrack {
                    Button(role: .destructive) { player.cancelSleep() } label: { Label("Выключить таймер", systemImage: "xmark") }
                }
                ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                    Button("Через \(minutes) мин") { player.sleep(minutes: minutes) }
                }
                Button("Когда закончится песня") { player.sleepAtTrackEnd() }
            } label: {
                sleepLabel
            }
            Spacer()
            Button { showEqualizer = true } label: {
                Image(systemName: "slider.vertical.3")
                    .foregroundStyle(audio.eqOn ? Theme.accent : Theme.ink)
            }
            .accessibilityLabel("Эквалайзер")
            Spacer()
            Menu {
                Button { picking = true } label: { Label("В плейлист…", systemImage: "text.badge.plus") }
                if track.isYouTube {
                    Button { player.playSingle(track) } label: { Label("Похожие треки", systemImage: "dot.radiowaves.left.and.right") }
                    if let link = URL(string: track.url) {
                        ShareLink(item: link) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                    }
                    Button(role: .destructive) {
                        library.toggleDislike(track)
                        player.next()
                    } label: { Label("Не нравится", systemImage: "hand.thumbsdown") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Ещё")
            Spacer()
            paneButton(.queue, "list.bullet", "Очередь")
        }
        .font(.title3)
        .foregroundStyle(Theme.ink)
        .buttonStyle(.plain)
    }

    @ViewBuilder private var sleepLabel: some View {
        if let at = player.sleepAt {
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz.fill")
                Text(at, style: .timer).font(.caption.monospacedDigit())
            }
            .foregroundStyle(Theme.accent)
        } else {
            Image(systemName: player.sleepAfterTrack ? "moon.zzz.fill" : "moon.zzz")
                .foregroundStyle(player.sleepAfterTrack ? Theme.accent : Theme.ink)
        }
    }

    private func paneButton(_ which: Pane, _ icon: String, _ label: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { pane = pane == which ? .cover : which }
        } label: {
            Image(systemName: icon)
                .foregroundStyle(pane == which ? Theme.accent : Theme.ink)
        }
        .accessibilityLabel(label)
    }
}

/// the words of the song; synced lines follow the music and can be tapped
struct LyricsPane: View {
    @EnvironmentObject private var player: Player
    let track: Track
    @State private var lyrics: Lyrics?
    @State private var lines: [LyricLine] = []
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !lines.isEmpty {
                synced
            } else if let plain = lyrics?.plain {
                ScrollView {
                    Text(plain)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                }
            } else {
                EmptyNote(icon: "quote.bubble", title: "Текста нет", text: "LRCLIB пока не знает слов этой песни.")
                    .frame(maxHeight: .infinity)
            }
        }
        .task(id: track.id) {
            loading = true
            lyrics = await LyricsService.shared.find(track)
            lines = lyrics?.synced.map(LyricsService.parseSynced) ?? []
            loading = false
        }
    }

    private var synced: some View {
        let now = LyricsService.current(lines, at: player.position)
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(line.id == now ? Theme.ink : Theme.muted.opacity(line.id < (now ?? -1) ? 0.6 : 1))
                            .scaleEffect(line.id == now ? 1.03 : 1, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                            .onTapGesture { player.seek(to: line.time) }
                    }
                }
                .padding(.vertical, 60)
            }
            .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .top, endPoint: .bottom))
            .onChange(of: now) { id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// what plays next: drag to reorder, swipe to remove
struct QueuePane: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(player.isWave ? "Моя волна" : "Дальше").font(.headline).foregroundStyle(Theme.ink)
                Spacer()
                if !player.upcoming.isEmpty {
                    Button("Очистить") { player.clearUpcoming() }.font(.subheadline)
                }
            }
            List {
                ForEach(Array(player.upcoming.enumerated()), id: \.element.id) { offset, track in
                    TrackRow(track: track)
                        .listRowBackground(Color.clear)
                        .onTapGesture { player.jump(to: player.index + 1 + offset) }
                }
                .onDelete { player.removeUpcoming(at: $0) }
                .onMove { player.moveUpcoming(from: $0, to: $1) }
                if player.upcoming.isEmpty {
                    Text(player.autoContinue ? "Дальше будут похожие песни" : "Очередь закончилась")
                        .foregroundStyle(Theme.muted)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
        }
    }
}

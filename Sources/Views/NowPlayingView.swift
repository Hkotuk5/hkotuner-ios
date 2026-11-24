import SwiftUI

/// The song on the whole screen: cover (swipe it for the next or previous
/// song), lyrics or the queue in its place, a scrubber and the controls.
struct NowPlayingView: View {
    enum Pane { case cover, lyrics, queue }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var audio = AudioSettings.shared
    @State private var picking = false
    @State private var pane = Pane.cover
    @State private var showEqualizer = false
    @State private var showArtist = false
    @State private var swipe: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let track = player.current {
                Group {
                    switch pane {
                    case .cover:
                        cover(track)
                            .transition(paneTransition)
                    case .lyrics:
                        VStack(spacing: 0) {
                            compactHeader(track)
                            LyricsPane(track: track)
                                .id(track.id)
                        }
                        .transition(paneTransition)
                    case .queue:
                        VStack(spacing: 0) {
                            compactHeader(track)
                            QueuePane()
                        }
                        .transition(paneTransition)
                    }
                }
                .frame(maxHeight: .infinity)
                if pane == .cover {
                    titleRow(track).padding(.top, 20).transition(.opacity)
                }
                Scrubber(
                    position: player.position,
                    length: player.length,
                    note: player.viaWeb
                        ? (player.webAd ? "реклама" : "через YouTube")
                        : (!player.throughEngine && !player.isLoading
                           ? (track.isSoundCloud ? "SoundCloud" : (track.isYouTube || track.isAudioStream ? "поток" : nil))
                           : nil),
                    onSeek: { player.seek(to: $0) }
                )
                .padding(.top, 14)
                .disabled(player.length <= 0)
                controls.padding(.top, 6)
                bottomBar(track).padding(.top, 18)
            } else {
                EmptyNote(icon: "music.note", title: "Ничего не играет")
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // the blurred cover stays behind and never widens the layout
        .background { backdrop }
        .overlay(alignment: .top) { Toast() }
        .presentationDragIndicator(.hidden)
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

    private var paneTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .offset(y: 8))
    }

    // MARK: parts

    private var backdrop: some View {
        ZStack {
            Theme.background
            Color.clear
                .overlay {
                    if let url = player.current?.thumbnailURL {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Color.clear
                            }
                        }
                        .blur(radius: 80)
                        .opacity(0.6)
                    }
                }
                .clipped()
            LinearGradient(
                colors: [Theme.background.opacity(0.15), Theme.background.opacity(0.55), Theme.background.opacity(0.95)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: player.current?.id)
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Свернуть")
            Spacer()
            VStack(spacing: 2) {
                Text(player.isWave ? "Моя волна" : "Сейчас играет")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                if !player.isWave && player.queue.count > 1 {
                    Text("\(player.index + 1) из \(player.queue.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            if let track = player.current {
                moreMenu(track)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .foregroundStyle(Theme.ink)
        .buttonStyle(.plain)
        .padding(.horizontal, -10)
        .padding(.top, 6)
    }

    private func cover(_ track: Track) -> some View {
        GeometryReader { geo in
            let side = max(0, min(geo.size.width, geo.size.height))
            ZStack {
                Artwork(url: track.thumbnailURL, size: side, radius: 22)
                    .id(track.id)
                    .transition(.opacity)
            }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: track.id)
                .scaleEffect(reduceMotion || player.isPlaying || player.isLoading ? 1 : 0.86)
                .shadow(color: .black.opacity(player.isPlaying ? 0.45 : 0.25), radius: 30, y: 16)
                .offset(x: swipe)
                .rotationEffect(.degrees(reduceMotion ? 0 : Double(swipe) / 40))
                .opacity(1 - min(0.5, abs(Double(swipe)) / 400))
                .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.78), value: player.isPlaying)
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { swipe = $0.translation.width }
                        .onEnded { value in
                            let dx = value.translation.width
                            if dx < -90 { player.next() } else if dx > 90 { player.previous() }
                            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) { swipe = 0 }
                        }
                )
                .accessibilityLabel("Обложка")
                .accessibilityHint("Смахни влево — следующая песня, вправо — предыдущая")
        }
        .padding(.top, 12)
    }

    /// a small cover and the names, above the lyrics or the queue
    private func compactHeader(_ track: Track) -> some View {
        HStack(spacing: 12) {
            Artwork(url: track.thumbnailURL, size: 56, radius: 10)
            names(track, big: false)
            likeButton(track)
        }
        .padding(.vertical, 12)
    }

    private func titleRow(_ track: Track) -> some View {
        HStack(alignment: .center, spacing: 12) {
            names(track, big: true)
            likeButton(track)
        }
    }

    private func names(_ track: Track, big: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(track.title)
                .font(big ? .title2.weight(.bold) : .headline)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Button { if track.isYouTube { showArtist = true } } label: {
                Text(track.artist)
                    .font(big ? .body : .subheadline)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .disabled(!track.isYouTube)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func likeButton(_ track: Track) -> some View {
        let liked = library.isLiked(track)
        return Button {
            library.toggleLike(track)
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(liked ? Theme.accent : Theme.ink)
                .contentTransition(.opacity)
                .scaleEffect(liked && !reduceMotion ? 1.14 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.48), value: liked)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(liked ? "Убрать из любимых" : "В любимые")
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(player.repeatMode == .off ? Theme.muted : Theme.accent)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(repeatLabel)
            Spacer(minLength: 0)
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28))
                    .frame(width: 56, height: 56)
            }
            .accessibilityLabel("Предыдущий")
            Spacer(minLength: 0)
            Button { player.toggle() } label: {
                ZStack {
                    Circle().fill(Theme.accent)
                    PlaybackGlyph(playing: player.isPlaying, loading: player.isLoading)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.black)
                        .tint(.black)
                }
                .frame(width: 74, height: 74)
                .shadow(color: Theme.accent.opacity(0.35), radius: 16, y: 6)
            }
            .accessibilityLabel(player.isPlaying ? "Пауза" : "Играть")
            Spacer(minLength: 0)
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28))
                    .frame(width: 56, height: 56)
            }
            .accessibilityLabel("Следующий")
            Spacer(minLength: 0)
            Button { player.autoContinue.toggle() } label: {
                Image(systemName: "infinity")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(player.autoContinue ? Theme.accent : Theme.muted)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(player.autoContinue ? "Похожие после очереди: включено" : "Похожие после очереди: выключено")
        }
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
        HStack(spacing: 0) {
            paneButton(.lyrics, "quote.bubble", "Текст")
            Menu {
                if player.sleepAt != nil || player.sleepAfterTrack {
                    Button(role: .destructive) { player.cancelSleep() } label: { Label("Выключить таймер", systemImage: "xmark") }
                }
                ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                    Button("Через \(minutes) мин") { player.sleep(minutes: minutes) }
                }
                Button("Когда закончится песня") { player.sleepAtTrackEnd() }
            } label: {
                barItem(active: player.sleepAt != nil || player.sleepAfterTrack) { sleepLabel }
            }
            .accessibilityLabel("Таймер сна")
            Button { showEqualizer = true } label: {
                barItem(active: audio.eqOn) { Image(systemName: "slider.vertical.3") }
            }
            .accessibilityLabel("Эквалайзер")
            paneButton(.queue, "list.bullet", "Очередь")
        }
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(Theme.ink)
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .glassCard(radius: 26)
    }

    private func barItem<Content: View>(active: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .foregroundStyle(active ? Theme.accent : Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
    }

    @ViewBuilder private var sleepLabel: some View {
        if let at = player.sleepAt {
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz.fill")
                Text(at, style: .timer).font(.caption.monospacedDigit())
            }
        } else {
            Image(systemName: player.sleepAfterTrack ? "moon.zzz.fill" : "moon.zzz")
        }
    }

    private func paneButton(_ which: Pane, _ icon: String, _ label: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                pane = pane == which ? .cover : which
            }
        } label: {
            barItem(active: pane == which) { Image(systemName: icon) }
        }
        .accessibilityLabel(label)
    }

    private func moreMenu(_ track: Track) -> some View {
        Menu {
            Button { picking = true } label: { Label("В плейлист…", systemImage: "text.badge.plus") }
            DownloadAction(track: track)
            if track.isYouTube {
                Button { showArtist = true } label: { Label("Исполнитель", systemImage: "person") }
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
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Ещё")
    }
}

/// A thick progress line: drag anywhere on it to move through the song.
struct Scrubber: View {
    let position: Double
    let length: Double
    var note: String? = nil
    let onSeek: (Double) -> Void
    @State private var dragged: Double?

    var body: some View {
        let value = dragged ?? position
        let fraction = length > 0 ? min(1, max(0, value / length)) : 0
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ink.opacity(0.18))
                    Capsule().fill(dragged == nil ? Theme.ink.opacity(0.85) : Theme.accent)
                        .frame(width: geo.size.width * fraction)
                }
                .frame(height: dragged == nil ? 6 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard length > 0, geo.size.width > 0 else { return }
                            dragged = min(1, max(0, drag.location.x / geo.size.width)) * length
                        }
                        .onEnded { _ in
                            if let target = dragged { onSeek(target) }
                            dragged = nil
                        }
                )
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragged == nil)
            }
            .frame(height: 22)
            HStack {
                Text(Track.clock(value))
                Spacer()
                if let note { Text(note).font(.caption2.weight(.semibold)) }
                Spacer()
                Text("-" + Track.clock(max(0, length - value)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Позиция в песне")
        .accessibilityValue("\(Track.clock(value)) из \(Track.clock(length))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(length, position + 15))
            case .decrement: onSeek(max(0, position - 15))
            @unknown default: break
            }
        }
    }
}

/// the words of the song; synced lines follow the music and can be tapped
struct LyricsPane: View {
    @EnvironmentObject private var player: Player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            let found = await LyricsService.shared.find(track)
            guard !Task.isCancelled else { return }
            lyrics = found
            lines = found?.synced.map(LyricsService.parseSynced) ?? []
            loading = false
        }
    }

    private var synced: some View {
        let now = LyricsService.current(lines, at: player.position)
        return GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(lines) { line in
                            lyricRow(line, active: line.id == now, past: line.id < (now ?? -1))
                                .id(line.id)
                        }
                    }
                    .padding(.vertical, max(12, geometry.size.height / 2 - 24))
                }
                .mask {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.13),
                        .init(color: .black, location: 0.87),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
                .onAppear {
                    if let now { proxy.scrollTo(now, anchor: .center) }
                }
                .onChange(of: now) { id in
                    guard let id else {
                        if let first = lines.first { proxy.scrollTo(first.id, anchor: .center) }
                        return
                    }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.36)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private func lyricRow(_ line: LyricLine, active: Bool, past: Bool) -> some View {
        let text = line.text.isEmpty ? "♪" : line.text
        return Button { player.seek(to: line.time) } label: {
            Group {
                if active && !reduceMotion && !line.text.isEmpty {
                    LyricHighlight(
                        text: text,
                        offset: player.position - line.time,
                        span: LyricsService.lineSpan(line, in: lines, duration: player.length),
                        playing: player.isPlaying && !player.webAd
                    )
                } else {
                    Text(text).foregroundStyle(active ? Theme.ink : Theme.muted.opacity(past ? 0.78 : 1))
                }
            }
            .multilineTextAlignment(.leading)
            .font(.title3.weight(.bold))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .background(active ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 3)
                    .padding(.vertical, 9)
                    .opacity(active ? 1 : 0)
            }
            .offset(x: active && !reduceMotion ? 3 : 0)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.23), value: active)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct LyricHighlight: View {
    let text: String
    let offset: Double
    let span: Double
    let playing: Bool
    @State private var paintedOffset: Double

    init(text: String, offset: Double, span: Double, playing: Bool) {
        self.text = text
        self.offset = offset
        self.span = span
        self.playing = playing
        _paintedOffset = State(initialValue: offset)
    }

    var body: some View {
        Text(text)
            .modifier(LyricShimmer(progress: min(1, max(0, paintedOffset / span))))
            .onChange(of: offset) { updated in
                let step = updated - paintedOffset
                let advance = playing && step > 0 && step <= 0.85
                withAnimation(advance ? .linear(duration: 0.4) : nil) {
                    paintedOffset = updated
                }
            }
    }
}

private struct LyricShimmer: AnimatableModifier {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // Keep the highlight soft as it passes over letters and wrapped lines.
        let edge = progress * 1.2 - 0.1
        func location(_ offset: Double) -> CGFloat { CGFloat(min(1, max(0, edge + offset))) }
        return content.foregroundStyle(LinearGradient(stops: [
            .init(color: Theme.ink, location: location(-0.075)),
            .init(color: Theme.ink, location: location(-0.03)),
            .init(color: Theme.accent, location: location(0)),
            .init(color: Theme.ink.opacity(0.62), location: location(0.09))
        ], startPoint: .topLeading, endPoint: .bottomTrailing))
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

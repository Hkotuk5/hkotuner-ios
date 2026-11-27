import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import UIKit

/// The queue and what plays it: files on the phone go through AVAudioEngine
/// (equalizer, levelling), a stream iOS reads itself (HLS) goes through
/// AVPlayer. Background audio, the lock screen and Control Center, headphone
/// buttons, a sleep timer, and songs that keep coming (YouTube Music's radio)
/// when the queue runs out.
@MainActor
final class Player: ObservableObject {
    static let shared = Player()

    enum Repeat: String, CaseIterable {
        case off, all, one
    }

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var position: Double = 0
    @Published private(set) var length: Double = 0
    @Published private(set) var isWave = false
    @Published var repeatMode: Repeat = .off
    /// similar songs follow when the queue ends
    @Published var autoContinue = true
    @Published var message: String?
    /// true while the sound goes through the equalizer; a stream plays without it
    @Published private(set) var throughEngine = false
    @Published private(set) var sleepAt: Date?
    @Published private(set) var sleepAfterTrack = false
    /// the song plays on YouTube's own page (WebPlayer), not through the app
    @Published private(set) var viaWeb = false
    /// YouTube's page is showing an ad
    @Published private(set) var webAd = false
    @Published private(set) var desktop: DesktopPlaybackDevice?

    var current: Track? {
        if let desktop { return desktop.state.track }
        return queue.indices.contains(index) ? queue[index] : nil
    }

    var upcoming: [Track] {
        guard desktop == nil, queue.indices.contains(index + 1) else { return [] }
        return Array(queue[(index + 1)...])
    }

    let engine = EnginePlayer()
    private var stream = AVPlayer()
    private let web = WebPlayer.shared
    private enum Backend { case none, engine, stream, web }
    /// After a bot check or rate limit, give direct playback a break.
    private var webUntil: Date?
    private var backend = Backend.none

    private var ticker: Timer?
    private var loadTask: Task<Void, Never>?
    private typealias StreamRequest = Task<BufferedStream, Error>
    private var preparedStream: (id: String, url: String, request: StreamRequest)?
    private var desktopPoll: Task<Void, Never>?
    private var desktopCommand: Task<Void, Never>?
    private var desktopUpdatedAt = Date()
    private var extending = false
    private var failures = 0
    private var artwork: MPMediaItemArtwork?
    private var artworkFor: String?
    private var bag = Set<AnyCancellable>()
    private var streamStatus: AnyCancellable?
    private var itemStatus: AnyCancellable?
    private var streamDurationTask: Task<Void, Never>?
    private var streamDuration: Double?
    private var streamEnd: Double?
    /// where a song brought back from the last session starts
    private var resumeAt: Double?
    private var lastTick = Date()
    private var listened: Double = 0
    private var counted = false
    private var sinceSave: Double = 0

    private var library: LibraryStore { LibraryStore.shared }

    private init() {
        observeStream()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)

        engine.onFinish = { [weak self] in self?.finished() }
        web.onState = { [weak self] state in self?.webState(state) }
        web.onEnded = { [weak self] in
            guard let self, self.backend == .web else { return }
            self.finished()
        }
        web.onError = { [weak self] reason in
            guard let self, self.backend == .web, let track = self.current else { return }
            self.stopBackends()
            self.failed(track, HKError(reason))
        }
        // not AudioSettings.apply(): that asks for Player.shared, which is being made right now
        engine.setEqualizer(on: AudioSettings.shared.eqOn, gains: AudioSettings.shared.gains)

        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                let item = note.object as? AVPlayerItem
                Task { @MainActor in
                    guard let self, let item, item === self.stream.currentItem else { return }
                    self.finished()
                }
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                let item = note.object as? AVPlayerItem
                Task { @MainActor in
                    guard let self, let item, item === self.stream.currentItem else { return }
                    self.message = "Воспроизведение прервалось"
                    self.next()
                }
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                let event = Player.interruption(note)
                Task { @MainActor in self?.interrupted(began: event.began, resume: event.resume) }
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                let unplugged = Player.headphonesGone(note)
                Task { @MainActor in if unplugged { self?.pause() } }
            }
            .store(in: &bag)
        Player.setupRemoteCommands()
        restoreSession()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: what to play

    /// plays a list from one of its songs (a playlist, likes, history)
    func play(_ tracks: [Track], at start: Int = 0) {
        guard tracks.indices.contains(start) else { return }
        if desktop != nil {
            startOnDesktop(Array(tracks[start...]))
            return
        }
        isWave = false
        queue = tracks
        index = start
        load()
    }

    /// a song picked in search: similar songs follow it, not the next result
    func playSingle(_ track: Track) {
        if desktop != nil {
            startOnDesktop([track])
            return
        }
        isWave = false
        autoContinue = true
        queue = [track]
        index = 0
        load()
    }

    func shuffle(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        play(tracks.shuffled(), at: 0)
    }

    func playNext(_ track: Track) {
        guard desktop == nil else { message = "Очередью компьютера можно управлять на ПК."; return }
        guard let now = current else { return playSingle(track) }
        queue.removeAll { $0.id == track.id && $0.id != now.id }
        if let i = queue.firstIndex(where: { $0.id == now.id }) { index = i }
        if track.id != now.id { queue.insert(track, at: min(index + 1, queue.count)) }
        prefetchNext()
    }

    func addToQueue(_ tracks: [Track]) {
        guard desktop == nil else { message = "Очередью компьютера можно управлять на ПК."; return }
        guard current != nil else { return play(tracks) }
        let known = Set(queue.map(\.id))
        queue.append(contentsOf: tracks.filter { !known.contains($0.id) })
        prefetchNext()
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        load()
    }

    /// `offsets` count from the first upcoming song
    func removeUpcoming(at offsets: IndexSet) {
        let absolute = IndexSet(offsets.map { $0 + index + 1 }.filter { queue.indices.contains($0) })
        queue.remove(atOffsets: absolute)
        prefetchNext()
    }

    func moveUpcoming(from source: IndexSet, to destination: Int) {
        var rest = upcoming
        rest.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[...index]) + rest
        prefetchNext()
    }

    func clearUpcoming() {
        guard queue.indices.contains(index) else { return }
        queue = Array(queue[...index])
        prefetchNext()
    }

    /// «Моя волна»: an endless radio from the songs you like and play
    func startWave() {
        let seeds = (Array(library.library.liked.prefix(60)) + Array(library.library.history.prefix(40))).filter { $0.isYouTube }
        isWave = true
        autoContinue = true
        isLoading = true
        message = nil
        Task {
            do {
                var seed = seeds.randomElement()
                if seed == nil {
                    seed = try await YTMusic.search("popular songs", limit: 10).randomElement()
                }
                guard let id = seed?.videoId else { throw HKError("Не нашлось, с чего начать волну") }
                let radio = try await YTMusic.radio(videoId: id)
                let fresh = self.filterForRadio(radio, skipping: [])
                guard !fresh.isEmpty else { throw HKError("Волна пустая, попробуй ещё раз") }
                if self.desktop != nil {
                    self.startOnDesktop(Array(fresh.shuffled().prefix(24)))
                    self.isLoading = false
                    return
                }
                self.isWave = true
                self.queue = Array(fresh.shuffled().prefix(25))
                self.index = 0
                self.load()
            } catch {
                self.isLoading = false
                self.message = error.localizedDescription
            }
        }
    }

    // MARK: controls

    func toggle() {
        if desktop != nil { sendToDesktop(.toggle); return }
        switch backend {
        case .none:
            if current != nil && !isLoading { load(startAt: resumeAt) }
        case .engine:
            if engine.isPlaying { pause() } else { resume() }
        case .stream:
            if stream.timeControlStatus == .paused { resume() } else { pause() }
        case .web:
            if isPlaying || isLoading { pause() } else { resume() }
        }
    }

    func pause() {
        if desktop != nil { sendToDesktop(.pause); return }
        switch backend {
        case .engine: engine.pause()
        case .stream: stream.pause()
        case .web: web.setPlaying(false)
        case .none: break
        }
        isPlaying = false
        updateNowPlaying()
        saveSession()
    }

    private func resume() {
        try? AVAudioSession.sharedInstance().setActive(true)
        switch backend {
        case .engine:
            do { try engine.play() } catch { message = "Звук не включился: \(error.localizedDescription)"; return }
            isPlaying = true
        case .stream:
            stream.play()
        case .web:
            web.setPlaying(true)
        case .none:
            toggle()
            return
        }
        updateNowPlaying()
    }

    func next() {
        if desktop != nil { sendToDesktop(.next); return }
        if index + 1 < queue.count {
            index += 1
            load()
        } else if repeatMode == .all && !queue.isEmpty {
            index = 0
            load()
        } else if autoContinue && queue.contains(where: \.isYouTube) {
            Task {
                await self.extend()
                if self.index + 1 < self.queue.count {
                    self.index += 1
                    self.load()
                } else {
                    self.pause()
                }
            }
        } else {
            pause()
            seek(to: 0)
        }
    }

    func previous() {
        if desktop != nil { sendToDesktop(.previous); return }
        if position > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            load()
        }
    }

    func seek(to seconds: Double) {
        if desktop != nil {
            if seconds.isFinite { sendToDesktop(.seek(max(0, seconds))) }
            return
        }
        position = seconds
        switch backend {
        case .engine: engine.seek(to: seconds)
        case .stream: stream.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        case .web: web.seek(to: seconds)
        case .none: resumeAt = seconds
        }
        updateNowPlaying()
    }

    var lyricPosition: Double {
        guard isPlaying, desktop == nil else { return position }
        switch backend {
        case .engine: return engine.currentTime
        case .stream:
            let seconds = CMTimeGetSeconds(stream.currentTime())
            return seconds.isFinite ? min(seconds, streamEnd ?? seconds) : position
        case .web, .none: return position
        }
    }

    func cycleRepeat() {
        let all = Repeat.allCases
        repeatMode = all[(all.firstIndex(of: repeatMode)! + 1) % all.count]
    }

    // MARK: listening on the computer

    func listen(on device: DesktopPlaybackDevice) async throws {
        guard device.id != desktop?.id else { return }
        let oldDesktop = desktop
        let active = isPlaying || isLoading
        var selected = device
        if active, let track = current {
            let following = desktop == nil ? upcoming : []
            guard let action = Self.desktopStart([track] + following, at: position) else {
                throw HKError("Для переноса на ПК выбери трек YouTube или SoundCloud.")
            }
            selected = try await deliver(action, to: device.id)
            if let oldDesktop { _ = try? await deliver(.pause, to: oldDesktop.id) }
        }
        if desktop == nil {
            resumeAt = position
            saveSession()
        }
        loadTask?.cancel()
        preparedStream?.request.cancel()
        preparedStream = nil
        desktopPoll?.cancel()
        desktopCommand?.cancel()
        stopBackends()
        throughEngine = false
        isWave = false
        showDesktop(selected)
        updateNowPlaying()
        desktopPoll = Task { await monitorDesktop(device.id) }
    }

    func continueOnPhone() async throws {
        guard let device = desktop else { return }
        let state = try await deliver(.pause, to: device.id).state
        leaveDesktop()
        if let track = state.track {
            if let existing = queue.firstIndex(where: { $0.id == track.id }) {
                index = existing
            } else {
                queue = [track]
                index = 0
            }
            let resume = state.duration > 0 ? min(state.position, max(0, state.duration - 0.5)) : state.position
            load(startAt: resume)
        }
    }

    private static func desktopStart(_ tracks: [Track], at position: Double) -> DesktopPlaybackAction? {
        guard let first = tracks.first, first.isYouTube || first.isSoundCloud else { return nil }
        let portable = tracks.lazy.filter { $0.isYouTube || $0.isSoundCloud }.prefix(24)
        return .start(Array(portable), at: position.isFinite ? max(0, position) : 0)
    }

    private func startOnDesktop(_ tracks: [Track]) {
        guard let action = Self.desktopStart(tracks, at: 0) else {
            message = "Этот трек доступен только на iPhone."
            return
        }
        sendToDesktop(action)
    }

    private func sendToDesktop(_ action: DesktopPlaybackAction) {
        guard let device = desktop else { return }
        let prior = desktopCommand
        desktopCommand = Task {
            await prior?.value
            guard !Task.isCancelled, desktop?.id == device.id else { return }
            do {
                _ = try await DeviceSync.shared.desktopPlayback(.command(action, to: device.id))
            } catch {
                if !Task.isCancelled, desktop?.id == device.id { message = error.localizedDescription }
            }
        }
    }

    private func deliver(_ action: DesktopPlaybackAction, to device: String) async throws -> DesktopPlaybackDevice {
        let sync = DeviceSync.shared
        let sent = try await sync.desktopPlayback(.command(action, to: device))
        guard let sequence = sent.sequence else { throw HKError("ПК не принял команду.") }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        repeat {
            let response = try await sync.desktopPlayback(.devices)
            guard let computer = response.devices?.first(where: { $0.id == device }) else {
                throw HKError("Компьютер уже не в сети.")
            }
            if computer.acknowledged >= sequence { return computer }
            try await Task.sleep(nanoseconds: 500_000_000)
        } while clock.now < deadline
        throw HKError("ПК не подтвердил переключение.")
    }

    private func monitorDesktop(_ id: String) async {
        var lastContact = Date()
        while !Task.isCancelled, desktop?.id == id {
            do {
                let response = try await DeviceSync.shared.desktopPlayback(.devices)
                guard !Task.isCancelled, desktop?.id == id else { return }
                guard let device = response.devices?.first(where: { $0.id == id }) else { break }
                showDesktop(device)
                lastContact = Date()
            } catch {
                guard !Task.isCancelled, desktop?.id == id else { return }
                if Date().timeIntervalSince(lastContact) >= 15 || DeviceSync.shared.onlineUsername == nil { break }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        if !Task.isCancelled, desktop?.id == id {
            leaveDesktop()
            message = "Связь с компьютером потеряна."
        }
    }

    private func showDesktop(_ device: DesktopPlaybackDevice) {
        if desktop != device { desktop = device }
        let state = device.state
        desktopUpdatedAt = Date()
        position = state.position
        length = state.duration
        isPlaying = state.playing
        isLoading = state.loading
    }

    private func leaveDesktop() {
        desktopPoll?.cancel()
        desktopPoll = nil
        desktopCommand?.cancel()
        desktopCommand = nil
        desktop = nil
        isPlaying = false
        isLoading = false
        position = resumeAt ?? 0
        length = current?.duration ?? 0
        updateNowPlaying()
    }

    // MARK: sleep timer

    func sleep(minutes: Int) {
        sleepAfterTrack = false
        sleepAt = Date().addingTimeInterval(Double(minutes) * 60)
        setFade(1)
    }

    func sleepAtTrackEnd() {
        sleepAt = nil
        sleepAfterTrack = true
        setFade(1)
    }

    func cancelSleep() {
        sleepAt = nil
        sleepAfterTrack = false
        setFade(1)
    }

    private func setFade(_ value: Float) {
        engine.setFade(value)
        stream.volume = value
    }

    /// the levelling setting changed: the playing song takes the new level
    func levelChanged() {
        guard let track = current else { return }
        engine.setLevel(AudioSettings.shared.normalize ? Loudness.gain(for: track) : 1)
    }

    // MARK: loading

    private final class BufferedStream {
        let audio: EmbeddedAudioResolver.AudioAddress
        let player: AVPlayer
        private var readiness: AnyCancellable?

        init(_ audio: EmbeddedAudioResolver.AudioAddress) {
            self.audio = audio
            let item = AVPlayerItem(url: audio.url)
            item.preferredForwardBufferDuration = 3
            let player = AVPlayer(playerItem: item)
            self.player = player
            readiness = player.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .filter { $0 == .readyToPlay }
                .prefix(1)
                .sink { [weak player] _ in player?.preroll(atRate: 1) { _ in } }
        }

        func prepareForPlayback() {
            readiness?.cancel()
            player.cancelPendingPrerolls()
            player.currentItem?.preferredForwardBufferDuration = 0
        }
    }

    private func observeStream() {
        let player = stream
        player.automaticallyWaitsToMinimizeStalling = true
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        streamStatus = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak player] status in
                Task { @MainActor in
                    guard let self, let player, player === self.stream, self.backend == .stream else { return }
                    self.isPlaying = status != .paused
                    self.updateNowPlaying()
                }
            }
    }

    private func load(startAt: Double? = nil) {
        loadTask?.cancel()
        resumeAt = nil
        guard let track = current else { return }
        isLoading = true
        message = nil
        stopBackends()
        position = startAt ?? 0
        length = track.duration ?? 0
        listened = 0
        counted = false
        loadArtwork(for: track)
        updateNowPlaying()
        saveSession()

        let usePage = pageFirst(for: track)
        let warmed: StreamRequest?
        if !usePage, let preparedStream, preparedStream.id == track.id, preparedStream.url == track.url {
            warmed = preparedStream.request
        } else {
            preparedStream?.request.cancel()
            warmed = nil
        }
        preparedStream = nil
        if usePage {
            startWeb(track, at: startAt)
            return
        }

        // a song changed on the lock screen must finish loading in the background
        let background = UIApplication.shared.beginBackgroundTask(withName: "hkotuner.load")
        loadTask = Task {
            defer {
                warmed?.cancel()
                UIApplication.shared.endBackgroundTask(background)
            }
            do {
                let (source, buffered) = try await Player.source(for: track, warmed: warmed)
                guard !Task.isCancelled, self.current?.id == track.id else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                self.start(source, buffered: buffered, track: track, at: startAt)
                self.isLoading = false
                self.failures = 0
                self.library.pushHistory(track)
                self.updateNowPlaying()
                self.prefetchNext()
                if self.autoContinue && self.queue.count - self.index <= 2 {
                    await self.extend()
                }
            } catch {
                guard !Task.isCancelled, self.current?.id == track.id else { return }
                if self.pageHelps(track, after: error) {
                    if Self.providerLimited(error) {
                        self.webUntil = Date().addingTimeInterval(30 * 60)
                    }
                    self.startWeb(track, at: startAt)
                    return
                }
                self.failed(track, error)
            }
        }
    }

    // MARK: YouTube's own page

    /// Straight to the page in Always mode or during a direct playback cooldown.
    private func pageFirst(for track: Track) -> Bool {
        guard track.isYouTube, !Player.isOnPhone(track) else { return false }
        switch WebPlayer.mode {
        case "always": return true
        case "off": return false
        default: return (webUntil ?? .distantPast) > Date()
        }
    }

    /// YouTube said no to the app; its page may still play the song
    private func pageHelps(_ track: Track, after error: Error) -> Bool {
        guard WebPlayer.mode != "off", track.videoId != nil else { return false }
        return error is BotCheckError || error is HKError || error is HTTPStatusError
    }

    private func startWeb(_ track: Track, at: Double?) {
        guard let id = track.videoId else { return }
        loadTask?.cancel()
        stopBackends()
        backend = .web
        viaWeb = true
        throughEngine = false
        isLoading = true
        try? AVAudioSession.sharedInstance().setActive(true)
        web.play(videoId: id, at: at)
        library.pushHistory(track)
        updateNowPlaying()
        if autoContinue && queue.count - index <= 2 {
            Task { await self.extend() }
        }
    }

    func refreshWebPlaybackState() {
        guard backend == .web else { return }
        web.refreshPlaybackState()
    }

    private func webState(_ state: WebPlayer.State) {
        guard backend == .web else { return }
        webAd = state.ad
        if !state.ad {
            position = state.time
            if state.duration > 0, abs(state.duration - length) > 0.5 { length = state.duration }
        }
        let playing = !state.paused
        if isLoading && playing && !state.ad && state.time > 0 {
            isLoading = false
            failures = 0
        }
        if playing != isPlaying {
            isPlaying = playing
            updateNowPlaying()
            if !playing { saveSession() }
        }
    }

    private func start(_ source: PlaybackSource, buffered: BufferedStream?, track: Track, at: Double?) {
        if case .file(let url) = source {
            do {
                try engine.open(url)
                engine.setLevel(AudioSettings.shared.normalize ? Loudness.gain(for: track) : 1)
                engine.setFade(sleepFade)
                try engine.play(from: at ?? 0)
                backend = .engine
                throughEngine = true
                if engine.duration > 0 { length = engine.duration }
                isPlaying = true
                return
            } catch {
                // a file the engine cannot read may still play in AVPlayer
                engine.stop()
            }
        }
        let item: AVPlayerItem
        if let buffered, let readyItem = buffered.player.currentItem, readyItem.status != .failed {
            buffered.prepareForPlayback()
            stream = buffered.player
            observeStream()
            item = readyItem
        } else {
            item = AVPlayerItem(url: source.url)
            stream.replaceCurrentItem(with: item)
        }
        if case .stream(_, let duration) = source {
            streamDuration = StreamTiming.valid(duration) ?? StreamTiming.valid(track.duration)
            if let streamDuration { length = streamDuration }
        }
        watch(item, track: track)
        backend = .stream
        throughEngine = false
        stream.volume = sleepFade
        var seeking = false
        if let at, at > 0, streamDuration.map({ at < $0 }) ?? true {
            seeking = true
            stream.seek(to: CMTime(seconds: at, preferredTimescale: 600))
        }
        if !seeking, item.status == .readyToPlay, item.isPlaybackLikelyToKeepUp {
            stream.playImmediately(atRate: 1)
        } else {
            stream.play()
        }

        if streamDuration == nil, source.url.scheme == "https", source.url.pathExtension.lowercased() == "m3u8" {
            streamDurationTask = Task { [weak self, weak item] in
                guard let duration = await HLSPlaylistTiming.read(source.url), !Task.isCancelled,
                      let self, let item, item === self.stream.currentItem else { return }
                self.streamDuration = duration
                self.updateStreamTiming(item)
            }
        }
    }

    private func stopBackends() {
        if backend == .web { web.stop() }
        viaWeb = false
        webAd = false
        engine.stop()
        stream.pause()
        stream.replaceCurrentItem(with: nil)
        itemStatus = nil
        streamDurationTask?.cancel()
        streamDurationTask = nil
        streamDuration = nil
        streamEnd = nil
        backend = .none
        isPlaying = false
    }

    private func failed(_ track: Track, _ error: Error) {
        isLoading = false
        failures += 1
        if error is BotCheckError {
            // Skip other YouTube requests while the service is asking for a bot check.
            message = "«\(track.title)» YouTube сейчас не отдал. " + (error.localizedDescription)
            if let i = queue.indices.dropFirst(index + 1).first(where: {
                let candidate = queue[$0]
                return candidate.isSoundCloud || candidate.isAudioStream || Player.isOnPhone(candidate)
            }) {
                index = i
                load()
            }
            return
        }
        message = "«\(track.title)» не включился: \(error.localizedDescription)"
        if failures < 3 && index + 1 < queue.count {
            index += 1
            load()
        }
    }

    static func isOnPhone(_ track: Track) -> Bool {
        if Downloads.shared.source(for: track) != nil { return true }
        if track.isLocal { return true }
        guard let id = track.videoId else { return false }
        return AudioCache.localFile(id) != nil
    }

    /// An item can fail before it reaches its end. Drop a bad cached copy or allow a direct link to be retried.
    private func watch(_ item: AVPlayerItem, track: Track) {
        itemStatus = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard status == .failed else { return }
                let reason = item?.error?.localizedDescription ?? "ошибка воспроизведения"
                Task { @MainActor in
                    guard let self, let item, item === self.stream.currentItem, self.current?.id == track.id else { return }
                    if track.isAudioStream || track.isSoundCloud {
                        self.stopBackends()
                        self.resumeAt = self.position
                        self.updateNowPlaying()
                        self.failed(track, HKError(reason))
                        return
                    }
                    if let id = track.videoId, !AudioCache.isOffline(id) {
                        try? FileManager.default.removeItem(at: AudioCache.cacheFile(id))
                    }
                    self.message = "«\(track.title)» не играет: \(reason)"
                    self.next()
                }
            }
    }

    private static func source(for track: Track, warmed: StreamRequest?) async throws -> (PlaybackSource, BufferedStream?) {
        if let saved = Downloads.shared.source(for: track) { return (saved, nil) }
        if track.isAudioStream {
            guard let url = track.audioStreamURL else { throw HKError("нужна прямая HTTPS-ссылка на аудио") }
            return (.stream(url), try await buffered(warmed))
        }
        if track.isLocal {
            let file = LocalFiles.fileURL(track)
            guard FileManager.default.fileExists(atPath: file.path) else { throw HKError("файла больше нет на телефоне") }
            return (.file(file), nil)
        }
        let id = track.videoId
        guard track.isSoundCloud || id != nil else { throw HKError("этот трек играет только на компьютере") }
        if let id, let file = AudioCache.localFile(id) { return (.file(file), nil) }
        do {
            if let ready = try await buffered(warmed) {
                return (.stream(ready.audio.url, duration: ready.audio.duration), ready)
            }
            let audio = try await EmbeddedAudioResolver.address(for: track, download: false)
            return (.stream(audio.url, duration: audio.duration), nil)
        } catch {
            try Task.checkCancellation()
            guard !providerLimited(error), !track.isSoundCloud, let id else { throw error }
            return (try await AudioCache.shared.playable(videoId: id, preferStream: true), nil)
        }
    }

    private static func buffered(_ request: StreamRequest?) async throws -> BufferedStream? {
        guard let request else { return nil }
        let result = await withTaskCancellationHandler {
            await request.result
        } onCancel: {
            request.cancel()
        }
        try Task.checkCancellation()
        switch result {
        case .success(let ready) where ready.audio.reuseDeadline > Date(): return ready
        case .failure(let error) where providerLimited(error): throw error
        default: return nil
        }
    }

    private static func providerLimited(_ error: Error) -> Bool {
        error is BotCheckError || (error as? HTTPStatusError)?.code == 429
    }

    /// Resolve and buffer just the next item without playing it.
    private func prefetchNext() {
        let next = queue.indices.contains(index + 1) ? queue[index + 1] : nil
        if let preparedStream {
            if next?.id == preparedStream.id, next?.url == preparedStream.url { return }
            preparedStream.request.cancel()
            self.preparedStream = nil
        }
        guard backend != .none, !isLoading, length - position <= 60, let next,
              next.isYouTube || next.isSoundCloud || next.isAudioStream,
              !isOnPhoneForPrefetch(next), !pageFirst(for: next) else { return }
        let request = Task(priority: .utility) {
            let audio: EmbeddedAudioResolver.AudioAddress
            if let url = next.audioStreamURL {
                audio = .init(url: url, format: nil, hls: url.pathExtension.lowercased() == "m3u8", duration: next.duration)
            } else {
                audio = try await EmbeddedAudioResolver.address(for: next, download: false)
            }
            try Task.checkCancellation()
            return BufferedStream(audio)
        }
        preparedStream = (next.id, next.url, request)
    }

    private func isOnPhoneForPrefetch(_ track: Track) -> Bool {
        if Downloads.shared.source(for: track) != nil { return true }
        guard let id = track.videoId else { return false }
        return AudioCache.isOffline(id) || FileManager.default.fileExists(atPath: AudioCache.cacheFile(id).path)
    }

    /// more songs like the last YouTube one in the queue
    private func extend() async {
        guard !extending, let seed = queue.last(where: { $0.isYouTube })?.videoId else { return }
        extending = true
        defer { extending = false }
        do {
            let radio = try await YTMusic.radio(videoId: seed)
            guard !Task.isCancelled, desktop == nil else { return }
            let fresh = filterForRadio(radio, skipping: Set(queue.map(\.id)))
            queue.append(contentsOf: fresh.prefix(20))
            prefetchNext()
        } catch {
            // a skipped song cancels the search for similar ones; that is not a failure
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { return }
            message = "Не удалось подобрать похожие: \(error.localizedDescription)"
        }
    }

    private func filterForRadio(_ tracks: [Track], skipping: Set<String>) -> [Track] {
        let hidden = Set(library.library.disliked.map(\.id))
        let recent = Set(library.library.history.prefix(isWave ? 30 : 0).map(\.id))
        var seen = skipping
        var out: [Track] = []
        for t in tracks where !hidden.contains(t.id) && !recent.contains(t.id) && !seen.contains(t.id) {
            seen.insert(t.id)
            out.append(t)
        }
        return out
    }

    private func finished() {
        if sleepAfterTrack {
            cancelSleep()
            pause()
            seek(to: 0)
            return
        }
        if repeatMode == .one {
            seek(to: 0)
            resume()
        } else {
            next()
        }
    }

    // MARK: the clock

    private func updateStreamTiming(_ item: AVPlayerItem) {
        let timing = StreamTiming(reported: item.duration.seconds, reference: streamDuration)
        if streamEnd != timing.end {
            streamEnd = timing.end
            item.forwardPlaybackEndTime = timing.end.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .invalid
        }
        if timing.length > 0, abs(timing.length - length) > 0.5 {
            length = timing.length
            updateNowPlaying()
        }
    }

    private var sleepFade: Float {
        guard let sleepAt else { return 1 }
        let left = sleepAt.timeIntervalSinceNow
        return left < 12 ? Float(max(0, left / 12)) : 1
    }

    private func tick() {
        let now = Date()
        let delta = min(2, now.timeIntervalSince(lastTick))
        lastTick = now
        if let desktop {
            if desktop.state.playing && !desktop.state.loading {
                let at = desktop.state.position + max(0, now.timeIntervalSince(desktopUpdatedAt))
                position = length > 0 ? min(at, length) : at
            }
            return
        }
        switch backend {
        case .engine:
            position = engine.currentTime
        case .stream:
            let seconds = CMTimeGetSeconds(stream.currentTime())
            if let item = stream.currentItem { updateStreamTiming(item) }
            if seconds.isFinite { position = min(seconds, streamEnd ?? seconds) }
        case .web:
            break
        case .none:
            return
        }
        if let sleepAt {
            if sleepAt.timeIntervalSinceNow <= 0 {
                cancelSleep()
                pause()
            } else {
                setFade(sleepFade)
            }
        }
        guard isPlaying, !webAd, let track = current else { return }
        listened += delta
        StatsStore.shared.listen(track, seconds: delta)
        if !counted && listened >= min(30, max(10, length * 0.5)) {
            counted = true
            StatsStore.shared.countPlay(track)
        }
        sinceSave += delta
        if sinceSave >= 10 {
            sinceSave = 0
            if preparedStream == nil { prefetchNext() }
            saveSession()
        }
    }

    // MARK: the last session, back after a restart (paused)

    private struct Session: Codable {
        var queue: [Track]
        var index: Int
        var position: Double
        var wave: Bool
    }

    func saveSession() {
        guard desktop == nil else { return }
        guard !queue.isEmpty else {
            UserDefaults.standard.removeObject(forKey: "session.v1")
            return
        }
        let from = max(0, index - 50)
        let kept = Array(queue[from..<min(queue.count, index + 150)])
        let session = Session(queue: kept, index: index - from, position: position, wave: isWave)
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: "session.v1")
        }
    }

    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: "session.v1"),
              let session = try? JSONDecoder().decode(Session.self, from: data),
              session.queue.indices.contains(session.index) else { return }
        queue = session.queue
        index = session.index
        isWave = session.wave
        position = session.position
        resumeAt = session.position > 5 ? session.position : nil
        length = queue[index].duration ?? 0
        if let track = current { loadArtwork(for: track) }
        updateNowPlaying()
    }

    // MARK: interruptions and headphones

    nonisolated private static func interruption(_ note: Notification) -> (began: Bool, resume: Bool) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return (false, false) }
        if type == .began { return (true, false) }
        let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        return (false, AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
    }

    nonisolated private static func headphonesGone(_ note: Notification) -> Bool {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return false }
        return AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
    }

    private func interrupted(began: Bool, resume shouldResume: Bool) {
        if began {
            if backend == .engine { engine.pause() }
            isPlaying = false
            updateNowPlaying()
        } else if shouldResume {
            resume()
        }
    }

    // MARK: lock screen and Control Center

    /// MediaPlayer calls these handlers off the main thread, so they are built
    /// outside the main actor and hop onto it
    nonisolated private static func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in
            Task { @MainActor in
                let player = Player.shared
                if !player.isPlaying { player.toggle() }
            }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { @MainActor in Player.shared.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in Player.shared.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            Task { @MainActor in Player.shared.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            Task { @MainActor in Player.shared.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = event.positionTime
            Task { @MainActor in Player.shared.seek(to: target) }
            return .success
        }
    }

    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func updateNowPlaying() {
        guard desktop == nil, let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: length,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let artwork, artworkFor == track.id { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for track: Track) {
        artwork = nil
        artworkFor = track.id
        guard let url = track.thumbnailURL else { return }
        Task {
            guard let (data, _) = try? await HTTP.session.data(from: url),
                  let image = UIImage(data: data),
                  self.artworkFor == track.id else { return }
            self.artwork = Player.makeArtwork(image)
            self.updateNowPlaying()
        }
    }
}

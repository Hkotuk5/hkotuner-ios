import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import UIKit

/// The queue and the one AVPlayer behind it: background audio, the lock
/// screen and Control Center, headphone buttons, and songs that keep coming
/// (YouTube Music's radio) when the queue runs out.
@MainActor
final class Player: ObservableObject {
    static let shared = Player()

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var position: Double = 0
    @Published private(set) var length: Double = 0
    @Published private(set) var isWave = false
    @Published var repeatOne = false
    /// similar songs follow when the queue ends
    @Published var autoContinue = true
    @Published var message: String?

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var upcoming: [Track] { queue.indices.contains(index + 1) ? Array(queue[(index + 1)...]) : [] }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var loadTask: Task<Void, Never>?
    private var extending = false
    private var failures = 0
    private var artwork: MPMediaItemArtwork?
    private var artworkFor: String?
    private var bag = Set<AnyCancellable>()
    private var itemStatus: AnyCancellable?

    private var library: LibraryStore { LibraryStore.shared }

    private init() {
        player.automaticallyWaitsToMinimizeStalling = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time) }
        }
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    self.isPlaying = status != .paused
                    self.updateNowPlaying()
                }
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                let item = note.object as? AVPlayerItem
                Task { @MainActor in
                    guard let self, let item, item === self.player.currentItem else { return }
                    self.finished()
                }
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                let item = note.object as? AVPlayerItem
                Task { @MainActor in
                    guard let self, let item, item === self.player.currentItem else { return }
                    self.message = "Воспроизведение прервалось"
                    self.next()
                }
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                let shouldResume = Player.shouldResume(after: note)
                Task { @MainActor in if shouldResume { self?.resumeAfterInterruption() } }
            }
            .store(in: &bag)
        Player.setupRemoteCommands()
    }

    // MARK: what to play

    /// plays a list from one of its songs (a playlist, likes, history)
    func play(_ tracks: [Track], at start: Int = 0) {
        guard tracks.indices.contains(start) else { return }
        isWave = false
        queue = tracks
        index = start
        load()
    }

    /// a song picked in search: similar songs follow it, not the next result
    func playSingle(_ track: Track) {
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
        guard let now = current else { return playSingle(track) }
        queue.removeAll { $0.id == track.id && $0.id != now.id }
        if let i = queue.firstIndex(where: { $0.id == now.id }) { index = i }
        if track.id != now.id { queue.insert(track, at: min(index + 1, queue.count)) }
        prefetchNext()
    }

    func addToQueue(_ tracks: [Track]) {
        guard current != nil else { return play(tracks) }
        let known = Set(queue.map(\.id))
        queue.append(contentsOf: tracks.filter { !known.contains($0.id) })
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
        if player.currentItem == nil {
            if current != nil && !isLoading { load() }
            return
        }
        if player.timeControlStatus == .paused {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
        } else {
            player.pause()
        }
    }

    func pause() { player.pause() }

    func next() {
        if index + 1 < queue.count {
            index += 1
            load()
        } else if autoContinue {
            Task {
                await self.extend()
                if self.index + 1 < self.queue.count {
                    self.index += 1
                    self.load()
                } else {
                    self.player.pause()
                }
            }
        } else {
            player.pause()
            seek(to: 0)
        }
    }

    func previous() {
        if position > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            load()
        }
    }

    func seek(to seconds: Double) {
        position = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    // MARK: loading

    private func load() {
        loadTask?.cancel()
        guard let track = current else { return }
        isLoading = true
        message = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        position = 0
        length = track.duration ?? 0
        loadArtwork(for: track)
        updateNowPlaying()

        // a song changed on the lock screen must finish loading in the background
        let background = UIApplication.shared.beginBackgroundTask(withName: "hkotuner.load")
        loadTask = Task {
            defer { UIApplication.shared.endBackgroundTask(background) }
            do {
                let source = try await Player.source(for: track)
                guard !Task.isCancelled, self.current?.id == track.id else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                let item = AVPlayerItem(url: source.url)
                self.watch(item, track: track)
                self.player.replaceCurrentItem(with: item)
                self.player.play()
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
                self.isLoading = false
                self.failures += 1
                self.message = "«\(track.title)» не включился: \(error.localizedDescription)"
                if self.failures < 3 && self.index + 1 < self.queue.count {
                    self.index += 1
                    self.load()
                }
            }
        }
    }

    /// a file that cannot be decoded never reaches its end: move on, and drop the bad copy
    private func watch(_ item: AVPlayerItem, track: Track) {
        itemStatus = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard status == .failed else { return }
                let reason = item?.error?.localizedDescription ?? "ошибка воспроизведения"
                Task { @MainActor in
                    guard let self, self.current?.id == track.id else { return }
                    if let id = track.videoId, !AudioCache.isOffline(id) {
                        try? FileManager.default.removeItem(at: AudioCache.cacheFile(id))
                    }
                    self.message = "«\(track.title)» не играет: \(reason)"
                    self.next()
                }
            }
    }

    private static func source(for track: Track) async throws -> PlaybackSource {
        if track.isLocal {
            let file = LocalFiles.fileURL(track)
            guard FileManager.default.fileExists(atPath: file.path) else { throw HKError("файла больше нет на телефоне") }
            return .file(file)
        }
        guard let id = track.videoId else { throw HKError("этот трек играет только на компьютере") }
        return try await AudioCache.shared.playable(videoId: id)
    }

    /// the next song is fetched while this one plays, so it starts at once
    private func prefetchNext() {
        guard let next = queue.dropFirst(index + 1).first(where: { $0.isYouTube }), let id = next.videoId else { return }
        Task.detached(priority: .utility) { _ = try? await AudioCache.shared.playable(videoId: id) }
    }

    /// more songs like the last YouTube one in the queue
    private func extend() async {
        guard !extending, let seed = queue.last(where: { $0.isYouTube })?.videoId else { return }
        extending = true
        defer { extending = false }
        do {
            let radio = try await YTMusic.radio(videoId: seed)
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
        if repeatOne {
            seek(to: 0)
            player.play()
        } else {
            next()
        }
    }

    private func tick(_ time: CMTime) {
        let seconds = CMTimeGetSeconds(time)
        if seconds.isFinite { position = seconds }
        if let d = player.currentItem?.duration, d.isNumeric {
            let total = CMTimeGetSeconds(d)
            if total.isFinite, total > 0, abs(total - length) > 0.5 {
                length = total
                updateNowPlaying()
            }
        }
    }

    nonisolated private static func shouldResume(after note: Notification) -> Bool {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended,
              let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
        else { return false }
        return AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
    }

    private func resumeAfterInterruption() {
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
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
        guard let track = current else {
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

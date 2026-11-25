import AVFoundation
import CryptoKit
import SwiftUI

enum YouTubeDownloadBlock: LocalizedError {
    case verificationRequired
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .verificationRequired:
            return "YouTube требует подтверждение и не разрешает скачивание. Для прослушивания онлайн открой «Плеер YouTube» в настройках."
        case .rateLimited:
            return "YouTube временно ограничил скачивание. Попробуй позже."
        }
    }
}

@MainActor
final class Downloads: ObservableObject {
    static let shared = Downloads()

    struct Entry: Codable {
        let track: Track
        let path: String
        let hls: Bool

        var url: URL {
            if hls {
                return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(path)
            }
            return Downloads.folder.appendingPathComponent(path)
        }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var running: Set<String> = []
    private var pendingPackages: [Int: URL] = [:]
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private let delegate = AssetDelegate()

    nonisolated private static let folder = AudioCache.offlineDir
    private let manifest = folder.appendingPathComponent("downloads.json")

    private lazy var session = AVAssetDownloadURLSession(
        configuration: .background(withIdentifier: "uk.hkot.hkotuner.downloads"),
        assetDownloadDelegate: delegate, delegateQueue: .main
    )

    private init() {
        if let raw = try? Data(contentsOf: manifest),
           let saved = try? JSONDecoder().decode([Entry].self, from: raw) {
            entries = saved.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
        delegate.store = self
    }

    func restoreSession() {
        session.getAllTasks { tasks in
            let ids = tasks.compactMap { Self.track(from: $0)?.id }
            Task { @MainActor in self.running.formUnion(ids) }
        }
    }

    func onBackgroundEvents(_ completion: @escaping () -> Void) {
        delegate.backgroundCompletion = completion
        restoreSession()
    }

    static func supports(_ track: Track) -> Bool { track.isYouTube || track.isSoundCloud || track.isAudioStream }

    func source(for track: Track) -> PlaybackSource? {
        if let entry = entries.first(where: { $0.track.id == track.id }),
           FileManager.default.fileExists(atPath: entry.url.path) {
            return entry.hls ? .stream(entry.url) : .file(entry.url)
        }
        if let id = track.videoId, AudioCache.isOffline(id) { return .file(AudioCache.offlineFile(id)) }
        return nil
    }

    func tracks(in library: Library) -> [Track] {
        var result = entries.filter { FileManager.default.fileExists(atPath: $0.url.path) }.map(\.track)
        var seen = Set(result.map(\.id))
        for track in library.liked + library.history + library.playlists.flatMap(\.tracks)
            where source(for: track) != nil && seen.insert(track.id).inserted {
            result.append(track)
        }
        return result
    }

    func keep(_ track: Track, youtubeBlock: YouTubeDownloadBlock? = nil) async throws {
        guard Self.supports(track), source(for: track) == nil, running.insert(track.id).inserted else { return }
        defer { running.remove(track.id) }

        let remote: EmbeddedAudioResolver.AudioAddress
        if track.isYouTube, let id = track.videoId {
            let cached = AudioCache.localFile(id)
            if cached == nil, let youtubeBlock { throw youtubeBlock }
            do {
                do {
                    if let file = cached {
                        try await saveFile(file, for: track, format: "m4a", move: false)
                        return
                    }
                    if case .file(let file) = try await AudioCache.shared.playable(videoId: id) {
                        try await saveFile(file, for: track, format: "m4a", move: false)
                        return
                    }
                } catch where !(error is CancellationError)
                    && !(error is BotCheckError)
                    && (error as? HTTPStatusError)?.code != 429 {
                    // The native resolver can supply a different format.
                }
                if let youtubeBlock { throw youtubeBlock }
                remote = try await EmbeddedAudioResolver.address(for: track, download: true)
            } catch is BotCheckError {
                throw YouTubeDownloadBlock.verificationRequired
            } catch let error as HTTPStatusError where error.code == 429 {
                throw YouTubeDownloadBlock.rateLimited
            }
        } else if let url = track.audioStreamURL {
            remote = .init(url: url, format: url.pathExtension.lowercased(), hls: url.pathExtension.lowercased() == "m3u8")
        } else {
            remote = try await EmbeddedAudioResolver.address(for: track, download: true)
        }
        if remote.hls {
            try await downloadHLS(remote.url, track: track)
        } else {
            let (temp, response) = try await URLSession.shared.download(from: remote.url)
            defer { try? FileManager.default.removeItem(at: temp) }
            if track.isYouTube, (response as? HTTPURLResponse)?.statusCode == 429 {
                throw YouTubeDownloadBlock.rateLimited
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.url?.scheme == "https" else { throw HKError("Не удалось скачать аудиофайл") }
            try await saveFile(temp, for: track, format: remote.format ?? "m4a", move: true)
        }
    }

    private func saveFile(_ source: URL, for track: Track, format: String, move: Bool) async throws {
        guard ["mp3", "m4a", "aac"].contains(format) else { throw HKError("Этот формат нельзя скачать") }
        let digest = SHA256.hash(data: Data(track.id.utf8)).map { String(format: "%02x", $0) }.joined()
        let entry = Entry(track: track, path: "\(digest).\(format)", hls: false)
        if FileManager.default.fileExists(atPath: entry.url.path) {
            try FileManager.default.removeItem(at: entry.url)
        }
        if move { try FileManager.default.moveItem(at: source, to: entry.url) }
        else { try FileManager.default.copyItem(at: source, to: entry.url) }
        do {
            guard try await AVURLAsset(url: entry.url).load(.isPlayable) else {
                throw HKError("Не удалось прочитать скачанный аудиофайл")
            }
            try save([entry] + entries.filter { $0.track.id != track.id })
        }
        catch { try? FileManager.default.removeItem(at: entry.url); throw error }
    }

    func remove(_ track: Track) throws {
        if let entry = entries.first(where: { $0.track.id == track.id }) {
            if FileManager.default.fileExists(atPath: entry.url.path) {
                try FileManager.default.removeItem(at: entry.url)
            }
            try save(entries.filter { $0.track.id != track.id })
        }
        if let id = track.videoId, AudioCache.isOffline(id) {
            try FileManager.default.removeItem(at: AudioCache.offlineFile(id))
            objectWillChange.send()
        }
    }

    private func save(_ updated: [Entry]) throws {
        try JSONEncoder().encode(updated).write(to: manifest, options: .atomic)
        entries = updated
    }

    private func downloadHLS(_ url: URL, track: Track) async throws {
        let config = AVAssetDownloadConfiguration(asset: AVURLAsset(url: url), title: track.title)
        let task = session.makeAssetDownloadTask(downloadConfiguration: config)
        task.taskDescription = String(decoding: try JSONEncoder().encode(track), as: UTF8.self)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[task.taskIdentifier] = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func track(from task: URLSessionTask) -> Track? {
        task.taskDescription.flatMap { try? JSONDecoder().decode(Track.self, from: Data($0.utf8)) }
    }

    private func finish(_ task: URLSessionTask, error: Error?) {
        let package = pendingPackages.removeValue(forKey: task.taskIdentifier)
        let waiter = waiters.removeValue(forKey: task.taskIdentifier)
        let result = Result<Void, Error> {
            if let error { throw error }
            let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.path + "/"
            guard let package, let track = Self.track(from: task),
                  package.standardizedFileURL.path.hasPrefix(home) else {
                throw HKError("Не удалось сохранить поток для офлайна")
            }
            let entry = Entry(track: track, path: String(package.standardizedFileURL.path.dropFirst(home.count)), hls: true)
            try save([entry] + entries.filter { $0.track.id != track.id })
        }
        if case .failure = result, let package { try? FileManager.default.removeItem(at: package) }
        if let id = Self.track(from: task)?.id { running.remove(id) }
        waiter?.resume(with: result)
    }

    private final class AssetDelegate: NSObject, AVAssetDownloadDelegate {
        weak var store: Downloads?
        var backgroundCompletion: (() -> Void)?

        func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
            MainActor.assumeIsolated {
                store?.pendingPackages[assetDownloadTask.taskIdentifier] = location
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            MainActor.assumeIsolated { store?.finish(task, error: error) }
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            MainActor.assumeIsolated {
                backgroundCompletion?()
                backgroundCompletion = nil
            }
        }
    }
}

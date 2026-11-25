import Foundation

enum PlaybackSource {
    /// a whole file on the phone
    case file(URL)
    /// a stream iOS reads itself (HLS), when the file could not be fetched
    case stream(URL, duration: Double? = nil)

    var url: URL {
        switch self {
        case .file(let url), .stream(let url, _): return url
        }
    }
}

/// Songs downloaded from YouTube: a cache the system may empty (Caches/audio,
/// kept under a size limit) and songs kept for offline (Application Support/offline).
actor AudioCache {
    static let shared = AudioCache()
    static let cacheLimit: Int64 = 600 << 20

    private var inflight: [String: Task<PlaybackSource, Error>] = [:]
    private var transfers: [String: Task<URL, Error>] = [:]

    static let cacheDir: URL = folder(.cachesDirectory, "audio")
    static let offlineDir: URL = folder(.applicationSupportDirectory, "offline")

    private static func folder(_ base: FileManager.SearchPathDirectory, _ name: String) -> URL {
        let dir = FileManager.default.urls(for: base, in: .userDomainMask)[0].appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func offlineFile(_ videoId: String) -> URL { offlineDir.appendingPathComponent("\(videoId).m4a") }
    static func cacheFile(_ videoId: String) -> URL { cacheDir.appendingPathComponent("\(videoId).m4a") }

    static func isOffline(_ videoId: String) -> Bool {
        FileManager.default.fileExists(atPath: offlineFile(videoId).path)
    }

    /// a file already on the phone, offline copies first
    static func localFile(_ videoId: String) -> URL? {
        let offline = offlineFile(videoId)
        if FileManager.default.fileExists(atPath: offline.path) { return offline }
        let cached = cacheFile(videoId)
        if FileManager.default.fileExists(atPath: cached.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cached.path)
            return cached
        }
        return nil
    }

    /// the song ready to play: from the phone, or fetched now (one fetch per song at a time)
    func playable(videoId: String, preferStream: Bool = false) async throws -> PlaybackSource {
        if let file = Self.localFile(videoId) { return .file(file) }
        let key = (preferStream ? "play:" : "file:") + videoId
        if let running = inflight[key] { return try await running.value }
        let task = Task { try await fetch(videoId, preferStream: preferStream) }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value
    }

    /// keeps a song on the phone for listening without internet
    func keepOffline(videoId: String) async throws {
        if Self.isOffline(videoId) { return }
        let cached = Self.cacheFile(videoId)
        if !FileManager.default.fileExists(atPath: cached.path) {
            guard case .file = try await playable(videoId: videoId) else {
                throw HKError("этот трек сейчас нельзя скачать")
            }
        }
        if FileManager.default.fileExists(atPath: cached.path) {
            try FileManager.default.moveItem(at: cached, to: Self.offlineFile(videoId))
        }
    }

    static func removeOffline(videoId: String) {
        let offline = offlineFile(videoId)
        guard FileManager.default.fileExists(atPath: offline.path) else { return }
        // back into the cache: it may still be played soon
        try? FileManager.default.removeItem(at: cacheFile(videoId))
        try? FileManager.default.moveItem(at: offline, to: cacheFile(videoId))
    }

    private func fetch(_ videoId: String, preferStream: Bool) async throws -> PlaybackSource {
        var lastError: Error = HKError("YouTube не отдал этот трек")
        var fallback: URL?
        for client in ClientConfigStore.shared.current.players {
            do {
                let stream = try await StreamResolver.resolve(videoId: videoId, client: client)
                if let db = stream.loudnessDb { Loudness.save(videoId, db) }
                if preferStream, let hls = stream.hls { return .stream(hls) }
                if fallback == nil { fallback = stream.hls }
                if let file = stream.file {
                    return .file(try await download(file, length: stream.contentLength, userAgent: stream.userAgent, videoId: videoId))
                }
            } catch {
                lastError = error
                // Stop requesting more addresses if YouTube asks us to back off.
                if error is BotCheckError || (error as? HTTPStatusError)?.code == 429 { break }
            }
        }
        if let fallback { return .stream(fallback) }
        throw lastError
    }

    private func download(_ url: URL, length: Int?, userAgent: String, videoId: String) async throws -> URL {
        if let file = Self.localFile(videoId) { return file }
        if let existing = transfers[videoId] { return try await existing.value }
        let destination = Self.cacheFile(videoId)
        let task = Task {
            try await ChunkedDownload.fetch(url, length: length, userAgent: userAgent, to: destination)
            Self.trim()
            return destination
        }
        transfers[videoId] = task
        defer { transfers[videoId] = nil }
        return try await task.value
    }

    static func bytes(in dir: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func offlineCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: offlineDir.path)) ?? []).filter { $0.hasSuffix(".m4a") }.count
    }

    static func clearCache() {
        for file in (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// the oldest played songs go first once the cache is over its limit
    static func trim() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        var files = ((try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: keys)) ?? [])
            .map { url -> (URL, Int64, Date) in
                let v = try? url.resourceValues(forKeys: Set(keys))
                return (url, Int64(v?.fileSize ?? 0), v?.contentModificationDate ?? .distantPast)
            }
        var total = files.reduce(0) { $0 + $1.1 }
        guard total > cacheLimit else { return }
        files.sort { $0.2 < $1.2 }
        for (url, size, _) in files where total > cacheLimit {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }
}

import Foundation

/// Where a song's audio lives, as YouTube's player API tells one client.
struct ResolvedStream {
    /// a single AAC (m4a) file, read in 1 MB parts
    var file: URL?
    var contentLength: Int?
    /// the HLS manifest of the same answer; iOS plays it itself (not cached)
    var hls: URL?
    var userAgent: String
    /// how much louder than YouTube's target level the song is, in dB
    var loudnessDb: Double? = nil
}

/// Asks YouTube's `/player` endpoint for a song's audio, as a client that needs
/// neither a PO token nor JavaScript (see ClientConfig). yt-dlp does the same
/// on the desktop; there is no yt-dlp on iOS.
enum StreamResolver {
    static func resolve(videoId: String, client: PlayerClient) async throws -> ResolvedStream {
        guard Track.isVideoId(videoId) else { throw HKError("это не трек YouTube") }
        let body: [String: Any] = [
            "context": ["client": client.contextClient],
            "videoId": videoId,
            "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        let root = try await HTTP.postJSON(
            URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!,
            body: body,
            headers: [
                "User-Agent": client.userAgent,
                "X-YouTube-Client-Name": String(client.nameId),
                "X-YouTube-Client-Version": client.version,
                "Origin": "https://www.youtube.com",
            ],
            what: "YouTube"
        )
        return try parse(root, userAgent: client.userAgent)
    }

    static func parse(_ root: Any, userAgent: String) throws -> ResolvedStream {
        let status = JSONTree.string(root, "/playabilityStatus/status") ?? ""
        guard status == "OK" else {
            let reason = JSONTree.string(root, "/playabilityStatus/reason") ?? status
            if isBotCheck(reason) { throw BotCheckError() }
            throw HKError(reason.isEmpty ? "YouTube не отдал этот трек" : "YouTube: \(reason)")
        }
        let best = pickAudio(root)
        let hls = JSONTree.string(root, "/streamingData/hlsManifestUrl").flatMap(URL.init(string:))
        guard best != nil || hls != nil else { throw HKError("у трека нет звука, который можно играть") }
        let loudness = (JSONTree.pointer(root, "/playerConfig/audioConfig/loudnessDb") as? Double)
            ?? (JSONTree.pointer(root, "/playerConfig/audioConfig/perceptualLoudnessDb") as? Double).map { $0 + 14 }
        return ResolvedStream(file: best?.url, contentLength: best?.length, hls: hls, userAgent: userAgent,
                              loudnessDb: loudness.flatMap { $0.isFinite ? $0 : nil })
    }

    /// "Sign in to confirm you’re not a bot"
    static func isBotCheck(_ reason: String) -> Bool {
        let r = reason.lowercased()
        return r.contains("not a bot") || r.contains("confirm you") && r.contains("bot")
    }

    /// the AAC audio format: itag 140 (128 kbit/s) when there, else the best m4a
    static func pickAudio(_ root: Any) -> (url: URL, length: Int?)? {
        guard let formats = JSONTree.pointer(root, "/streamingData/adaptiveFormats") as? [Any] else { return nil }
        var candidates: [(itag: Int, bitrate: Int, url: URL, length: Int?)] = []
        for case let f as [String: Any] in formats {
            guard let mime = f["mimeType"] as? String, mime.hasPrefix("audio/mp4"),
                  let raw = f["url"] as? String, let url = URL(string: raw) else { continue }
            let length = (f["contentLength"] as? String).flatMap(Int.init)
            candidates.append((f["itag"] as? Int ?? 0, f["bitrate"] as? Int ?? 0, url, length))
        }
        if let aac = candidates.first(where: { $0.itag == 140 }) { return (aac.url, aac.length) }
        return candidates.max(by: { $0.bitrate < $1.bitrate }).map { ($0.url, $0.length) }
    }
}

/// Downloads a googlevideo file in parallel 1 MB ranges: one plain request is
/// held to ~32 KB/s, while ranged parts arrive in a fraction of a second.
enum ChunkedDownload {
    static let chunk = 1 << 20
    static let parallel = 4

    static func fetch(_ url: URL, length: Int?, userAgent: String, to destination: URL) async throws {
        var declared = length
        var firstPart: Data?
        if declared == nil {
            let (data, http) = try await range(url, 0, chunk - 1, userAgent: userAgent)
            firstPart = data
            declared = contentRangeTotal(http) ?? (http.statusCode == 200 ? data.count : nil)
        }
        guard let total = declared, total > 0, total < 200 << 20 else { throw HKError("YouTube не сказал размер файла") }

        let ranges: [(Int, Int)] = stride(from: 0, to: total, by: chunk).map { ($0, min($0 + chunk, total) - 1) }
        var parts = [Data?](repeating: nil, count: ranges.count)
        if let firstPart, firstPart.count == ranges[0].1 + 1 { parts[0] = firstPart }

        let todo = ranges.indices.filter { parts[$0] == nil }
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            let first = min(parallel, todo.count)
            for n in 0..<first {
                let i = todo[n]
                let (a, b) = ranges[i]
                group.addTask { (i, try await ChunkedDownload.part(url, a, b, userAgent: userAgent)) }
            }
            var next = first
            while let (i, data) = try await group.next() {
                parts[i] = data
                if next < todo.count {
                    let j = todo[next]
                    next += 1
                    let (a, b) = ranges[j]
                    group.addTask { (j, try await ChunkedDownload.part(url, a, b, userAgent: userAgent)) }
                }
            }
        }

        let tmp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).part")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        do {
            for case let data? in parts { try handle.write(contentsOf: data) }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
    }

    /// one range, retried twice; it must come back whole
    private static func part(_ url: URL, _ a: Int, _ b: Int, userAgent: String) async throws -> Data {
        var lastError: Error = HKError("не удалось скачать трек")
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000) }
            do {
                let (data, _) = try await range(url, a, b, userAgent: userAgent)
                if data.count == b - a + 1 { return data }
                lastError = HKError("YouTube прислал неполный кусок")
            } catch let error as HKError where error.message.contains("403") {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func range(_ url: URL, _ a: Int, _ b: Int, userAgent: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(a)-\(b)", forHTTPHeaderField: "Range")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await HTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HKError("нет ответа от YouTube") }
        guard http.statusCode == 206 || http.statusCode == 200 else {
            throw HKError("YouTube не отдал звук (\(http.statusCode))")
        }
        return (data, http)
    }

    /// "bytes 0-1048575/3449447" → 3449447
    static func contentRangeTotal(_ http: HTTPURLResponse) -> Int? {
        guard let value = http.value(forHTTPHeaderField: "Content-Range"),
              let slash = value.lastIndex(of: "/") else { return nil }
        return Int(value[value.index(after: slash)...])
    }
}

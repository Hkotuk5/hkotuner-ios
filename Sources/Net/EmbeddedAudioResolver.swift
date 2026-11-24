import Foundation

enum EmbeddedAudioResolver {
    private static let queue = DispatchQueue(label: "uk.hkot.hkotuner.audioResolver", qos: .userInitiated)

    static func searchSoundCloud(_ query: String) async throws -> [Track] {
        let response = try await request("search", query, provider: "SoundCloud")
        guard let tracks = response.tracks else { throw HKError("SoundCloud не вернул результаты поиска") }
        var known = Set<String>()
        return tracks.filter { $0.isSoundCloud && known.insert($0.id).inserted }
    }

    struct AudioAddress: Sendable {
        let url: URL
        let format: String?
        let hls: Bool
        let duration: Double?
        let reuseDeadline: Date
    }

    static func reuseDeadline(for url: URL, from now: Date) -> Date {
        let shortLifetime = now.addingTimeInterval(120)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let expirations = items.compactMap { item -> Date? in
            guard ["expire", "expires"].contains(item.name.lowercased()),
                  let value = item.value, let epoch = TimeInterval(value), epoch.isFinite else { return nil }
            return Date(timeIntervalSince1970: epoch - 20)
        }
        return min(shortLifetime, expirations.min() ?? shortLifetime)
    }

    static func address(for track: Track, download: Bool) async throws -> AudioAddress {
        let provider = track.isSoundCloud ? "SoundCloud" : "YouTube"
        let address = track.videoId.map { "https://music.youtube.com/watch?v=\($0)" } ?? track.url
        let response = try await request(download ? "download" : "resolve", address, provider: provider)
        guard let url = response.url, url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw HKError("\(provider) не отдал аудиопоток")
        }
        return AudioAddress(url: url, format: response.format, hls: response.protocolName?.hasPrefix("m3u8") == true,
                            duration: response.duration, reuseDeadline: reuseDeadline(for: url, from: Date()))
    }

    private struct Response: Decodable {
        var error: String?
        var url: URL?
        var tracks: [Track]?
        var format: String?
        var duration: Double?
        var protocolName: String?

        enum CodingKeys: String, CodingKey {
            case error, url, tracks, format, duration
            case protocolName = "protocol"
        }
    }

    private final class RequestCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private static func request(_ operation: String, _ value: String, provider: String) async throws -> Response {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(["operation": operation, "value": value])
        let input = String(decoding: data, as: UTF8.self)
        let cancellation = RequestCancellation()
        let response: Response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard let output = HKPythonAudioRequest(input) else {
                        continuation.resume(throwing: HKError("Встроенный модуль аудио не запустился"))
                        return
                    }
                    continuation.resume(with: Result { try JSONDecoder().decode(Response.self, from: Data(output.utf8)) })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        switch response.error {
        case nil: return response
        case "bot_check" where provider == "YouTube": throw BotCheckError()
        case "rate_limited": throw HTTPStatusError(code: 429, what: provider)
        case "runtime_error": throw HKError("Ошибка встроенного модуля аудио")
        default: throw HKError("\(provider) не предоставил доступный аудиопоток")
        }
    }
}

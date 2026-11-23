import Foundation

enum EmbeddedAudioResolver {
    private static let queue = DispatchQueue(label: "uk.hkot.hkotuner.audioResolver", qos: .userInitiated)

    static func searchSoundCloud(_ query: String) async throws -> [Track] {
        let response = try await request("search", query, provider: "SoundCloud")
        guard let tracks = response.tracks else { throw HKError("SoundCloud не вернул результаты поиска") }
        var known = Set<String>()
        return tracks.filter { $0.isSoundCloud && known.insert($0.id).inserted }
    }

    static func stream(for track: Track) async throws -> URL {
        let provider = track.isSoundCloud ? "SoundCloud" : "YouTube"
        let address = track.videoId.map { "https://music.youtube.com/watch?v=\($0)" } ?? track.url
        let response = try await request("resolve", address, provider: provider)
        guard let url = response.url, url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw HKError("\(provider) не отдал аудиопоток")
        }
        return url
    }

    private struct Response: Decodable {
        var error: String?
        var url: URL?
        var tracks: [Track]?
    }

    private static func request(_ operation: String, _ value: String, provider: String) async throws -> Response {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(["operation": operation, "value": value])
        let input = String(decoding: data, as: UTF8.self)
        let response: Response = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let output = HKPythonAudioRequest(input) else {
                    continuation.resume(throwing: HKError("Встроенный модуль аудио не запустился"))
                    return
                }
                continuation.resume(with: Result { try JSONDecoder().decode(Response.self, from: Data(output.utf8)) })
            }
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

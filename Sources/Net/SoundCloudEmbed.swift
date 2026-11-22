import Foundation

struct SoundCloudEmbed: Identifiable {
    let url: URL
    var id: URL { url }

    init?(_ text: String) {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: address), parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(),
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        let path = parts.path.split(separator: "/")
        switch host {
        case "soundcloud.com", "www.soundcloud.com", "m.soundcloud.com":
            guard path.count == 2 || (path.count == 3 && path[1] == "sets") else { return nil }
            parts.host = "soundcloud.com"
        case "on.soundcloud.com":
            guard path.count == 1 else { return nil }
        default:
            return nil
        }
        parts.fragment = nil
        guard let url = parts.url else { return nil }
        self.url = url
    }

    func loadPlayerURL() async throws -> URL {
        var trackURL = url
        if url.host == "on.soundcloud.com" {
            trackURL = try await resolveShortLink()
        }
        var endpoint = URLComponents()
        endpoint.scheme = "https"
        endpoint.host = "soundcloud.com"
        endpoint.path = "/oembed"
        endpoint.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "url", value: trackURL.absoluteString),
        ]
        guard let requestURL = endpoint.url else { throw HKError("Не удалось открыть ссылку SoundCloud") }
        let data = try await HTTP.get(requestURL, what: "SoundCloud")
        guard let result = try? JSONDecoder().decode(Response.self, from: data),
              let playerURL = Self.playerURL(in: result.html) else {
            throw HKError("SoundCloud не предоставил встроенный плеер для этой ссылки")
        }
        return playerURL
    }

    private func resolveShortLink() async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        let (_, response) = try await HTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let address = http.url?.absoluteString, let track = Self(address),
              track.url.host == "soundcloud.com" else {
            throw HKError("Нужна ссылка на трек или плейлист SoundCloud")
        }
        return track.url
    }

    static func playerURL(in html: String) -> URL? {
        guard let start = html.range(of: " src=\""), let end = html[start.upperBound...].firstIndex(of: "\"") else { return nil }
        let address = html[start.upperBound..<end].replacingOccurrences(of: "&amp;", with: "&")
        guard let parts = URLComponents(string: address), parts.scheme == "https",
              parts.host == "w.soundcloud.com", parts.path == "/player/",
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        return parts.url
    }

    private struct Response: Decodable {
        let html: String
    }
}

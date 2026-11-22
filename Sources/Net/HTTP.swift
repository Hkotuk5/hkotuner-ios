import Foundation

struct HKError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// YouTube asked to prove this is not a bot. The app does not try to get
/// around it: it says what usually helps and plays what is already on the phone.
struct BotCheckError: LocalizedError {
    var errorDescription: String? {
        "YouTube просит подтвердить, что ты не бот. Обычно помогает выключить VPN или сменить сеть (Wi-Fi ↔ мобильный интернет). Скачанные песни играют как обычно."
    }
}

/// a server answered with an error status
struct HTTPStatusError: LocalizedError {
    let code: Int
    let what: String
    var errorDescription: String? {
        if code == 401 || code == 403 { return "\(what) не пустил (\(code))" }
        if code == 429 { return "\(what) просит подождать: слишком много запросов" }
        return "\(what) ответил \(code)"
    }
}

enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    /// names the app to services that ask for it (LRCLIB, GitHub); no personal data
    static let appAgent = "hkotuner-ios (https://github.com/Hkotuk5/hkotuner-ios)"

    /// a JSON POST that answers with JSON; `what` names the service in errors.
    /// `ownCookies` sends only the Cookie header given here, not the shared cookie jar.
    static func postJSON(_ url: URL, body: [String: Any], headers: [String: String], what: String,
                         ownCookies: Bool = false) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if ownCookies { request.httpShouldHandleCookies = false }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let data = try await send(request, what: what)
        do {
            return try JSONTree.parse(data)
        } catch {
            throw HKError("\(what) прислал непонятный ответ")
        }
    }

    static func getJSON(_ url: URL, headers: [String: String] = [:], what: String, timeout: TimeInterval = 15) async throws -> Any {
        let data = try await get(url, headers: headers, what: what, timeout: timeout)
        do {
            return try JSONTree.parse(data)
        } catch {
            throw HKError("\(what) прислал непонятный ответ")
        }
    }

    static func get(_ url: URL, headers: [String: String] = [:], what: String, timeout: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return try await send(request, what: what)
    }

    private static func send(_ request: URLRequest, what: String) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw HKError("\(what) недоступен: \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPStatusError(code: http.statusCode, what: what)
        }
        return data
    }
}

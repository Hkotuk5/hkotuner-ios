import Foundation

struct HKError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
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

    /// a JSON POST that answers with JSON; `what` names the service in errors
    static func postJSON(_ url: URL, body: [String: Any], headers: [String: String], what: String) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HKError("\(what) недоступен: \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HKError("\(what) ответил \(http.statusCode)")
        }
        do {
            return try JSONTree.parse(data)
        } catch {
            throw HKError("\(what) прислал непонятный ответ")
        }
    }
}

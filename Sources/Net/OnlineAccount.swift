import CryptoKit
import Foundation
import Security

struct OnlineAccount: Codable, Equatable {
    private static let serverAddress = "https://146.103.57.133"
    let server: URL
    let username: String
    private let token: String

    var identity: String {
        let hash = SHA256.hash(data: Data("\(server.absoluteString)|\(username.lowercased())".utf8))
        return "online-" + hash.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private struct Credentials: Encodable {
        let username: String
        let password: String
    }

    private struct Login: Decodable {
        let username: String
        let token: String
    }

    enum Failure: LocalizedError {
        case credentials
        case badUsername
        case weakPassword
        case usernameTaken
        case expired
        case tooManyAttempts
        case server
        case invalidAddress
        case tooLarge
        case tooManyDevices

        var errorDescription: String? {
            switch self {
            case .credentials: return "Неверный логин или пароль"
            case .badUsername: return "Логин: 3–24 латинские буквы, цифры или символы . _ -"
            case .weakPassword: return "Пароль должен быть от 12 символов, до 256 байт и отличаться от логина"
            case .usernameTaken: return "Этот логин уже занят"
            case .expired: return "Сессия закончилась. Войди в аккаунт снова."
            case .tooManyAttempts: return "Слишком много попыток. Попробуй позже."
            case .server: return "Сервер синхронизации сейчас недоступен"
            case .invalidAddress: return "Неверный HTTPS-адрес сервера"
            case .tooLarge: return "Слишком много данных для одной синхронизации"
            case .tooManyDevices: return "Достигнут лимит устройств этого аккаунта"
            }
        }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()

    static func endpoint(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = value.contains("://") ? value : "https://" + value
        guard var fields = URLComponents(string: address), fields.scheme?.lowercased() == "https",
              let host = fields.host, !host.isEmpty, fields.user == nil, fields.password == nil,
              (fields.path.isEmpty || fields.path == "/"), fields.query == nil, fields.fragment == nil else {
            throw Failure.invalidAddress
        }
        fields.scheme = "https"
        fields.host = host.lowercased()
        if fields.port == 443 { fields.port = nil }
        fields.path = ""
        guard let url = fields.url else { throw Failure.invalidAddress }
        return url
    }

    static func authenticate(username: String, password: String, registering: Bool) async throws -> Self {
        let url = try endpoint(serverAddress)
        let body = try JSONEncoder().encode(Credentials(username: username, password: password))
        let data = try await send(registering ? "register" : "login", server: url, token: nil, body: body)
        let reply = try JSONDecoder().decode(Login.self, from: data)
        guard reply.token.utf8.count == 43, !reply.username.isEmpty else { throw Failure.server }
        return Self(server: url, username: reply.username, token: reply.token)
    }

    func exchange(_ payload: Data) async throws -> Data {
        guard payload.count <= 24 * 1024 * 1024 else { throw Failure.tooLarge }
        return try await Self.send("sync", server: server, token: token, body: payload)
    }

    func playback(_ command: DesktopPlaybackRequest) async throws -> DesktopPlaybackReply {
        let body = try JSONEncoder().encode(command)
        let response = try await Self.send("playback", server: server, token: token, body: body)
        return try JSONDecoder().decode(DesktopPlaybackReply.self, from: response)
    }

    func signOut() async throws {
        _ = try await Self.send("logout", server: server, token: token, body: nil)
    }

    private static func send(_ action: String, server: URL, token: String?, body: Data?) async throws -> Data {
        var request = URLRequest(url: server.appendingPathComponent("v1").appendingPathComponent(action))
        request.httpMethod = "POST"
        if action == "playback" { request.timeoutInterval = 8 }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await http.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw Failure.server }
        switch status {
        case 200, 204: return data
        case 201 where action == "register": return data
        case 400 where action == "register":
            let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            if code == "bad_username" { throw Failure.badUsername }
            if code == "weak_password" { throw Failure.weakPassword }
            throw HKError("Проверь логин и пароль")
        case 401: throw token == nil ? Failure.credentials : Failure.expired
        case 404 where action == "register": throw HKError("Для регистрации обнови сервер hkotuner.")
        case 404 where action == "playback":
            if let error = try? JSONDecoder().decode([String: String].self, from: data),
               error["error"] == "device_unavailable" {
                throw HKError("Компьютер уже не в сети.")
            }
            throw HKError("Для выбора ПК обнови сервер hkotuner.")
        case 409: throw action == "register" ? Failure.usernameTaken : Failure.tooManyDevices
        case 413: throw Failure.tooLarge
        case 429: throw Failure.tooManyAttempts
        default: throw Failure.server
        }
    }

    private static let keychainQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "uk.hkot.hkotuner.online",
        kSecAttrAccount as String: "session"
    ]

    static func load() -> Self? {
        let options = keychainQuery.merging([kSecReturnData as String: true]) { _, requested in requested }
        var result: CFTypeRef?
        guard SecItemCopyMatching(options as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        let status = SecItemUpdate(Self.keychainQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = Self.keychainQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try Self.checkKeychain(SecItemAdd(query as CFDictionary, nil))
        } else {
            try Self.checkKeychain(status)
        }
    }

    static func remove() throws {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        if status != errSecItemNotFound { try checkKeychain(status) }
    }

    private static func checkKeychain(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw HKError("Не удалось изменить сессию в связке ключей") }
    }
}

import Foundation

/// How the app introduces itself to YouTube when it asks for a song's audio.
/// YouTube retires clients now and then (android_vr stopped working in
/// August 2026), so the list can be updated from `client-config.json` in the
/// app's GitHub repository without building a new .ipa.
struct PlayerClient: Codable, Hashable {
    var name: String
    var version: String
    /// X-YouTube-Client-Name
    var nameId: Int
    var userAgent: String
    var deviceMake: String?
    var deviceModel: String?
    var osName: String?
    var osVersion: String?

    var contextClient: [String: Any] {
        var c: [String: Any] = ["clientName": name, "clientVersion": version, "hl": "en", "gl": "US"]
        if let deviceMake { c["deviceMake"] = deviceMake }
        if let deviceModel { c["deviceModel"] = deviceModel }
        if let osName { c["osName"] = osName }
        if let osVersion { c["osVersion"] = osVersion }
        return c
    }

    var isSane: Bool {
        let fields = [name, version, userAgent, deviceMake ?? "", deviceModel ?? "", osName ?? "", osVersion ?? ""]
        return !name.isEmpty && !version.isEmpty && (1...500).contains(nameId)
            && fields.allSatisfy { $0.count <= 300 && !$0.contains("\n") }
    }
}

struct ClientConfig: Codable {
    static let schemaVersion = 1

    var schema: Int
    /// WEB_REMIX clientVersion for search and radio on music.youtube.com
    var musicClientVersion: String
    /// tried in order until one gives playable audio
    var players: [PlayerClient]

    /// what yt-dlp itself uses when it has no JavaScript runtime (checked 2026-11-22)
    static let builtIn = ClientConfig(
        schema: schemaVersion,
        musicClientVersion: "1.20260707.12.00",
        players: [
            PlayerClient(
                name: "VISIONOS", version: "1.02", nameId: 101,
                userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
                deviceMake: "Apple", deviceModel: "RealityDevice17,1", osName: "visionOS", osVersion: "26.5.23O471"
            ),
        ]
    )

    var isSane: Bool {
        schema == ClientConfig.schemaVersion && !players.isEmpty && players.count <= 8
            && players.allSatisfy(\.isSane) && !musicClientVersion.isEmpty && musicClientVersion.count < 40
    }
}

/// The config in use: the last good one from GitHub, else the built-in one.
final class ClientConfigStore {
    static let shared = ClientConfigStore()

    /// the public repository the iOS app is built from
    static let remoteURL = URL(string: "https://raw.githubusercontent.com/Hkotuk5/hkotuner-ios/main/client-config.json")!
    private static let defaultsKey = "clientConfig.v1"
    private static let checkedKey = "clientConfig.checkedAt"

    private let lock = NSLock()
    private var value: ClientConfig

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(ClientConfig.self, from: data), saved.isSane {
            value = saved
        } else {
            value = .builtIn
        }
    }

    var current: ClientConfig {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    var lastChecked: Date? {
        UserDefaults.standard.object(forKey: Self.checkedKey) as? Date
    }

    /// fetches the config from GitHub; a broken or missing file keeps what we have
    @discardableResult
    func refresh() async -> Bool {
        var request = URLRequest(url: Self.remoteURL)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await HTTP.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count < 64 * 1024,
              let fresh = try? JSONDecoder().decode(ClientConfig.self, from: data),
              fresh.isSane
        else { return false }
        store(fresh)
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        UserDefaults.standard.set(Date(), forKey: Self.checkedKey)
        return true
    }

    private func store(_ config: ClientConfig) {
        lock.lock()
        value = config
        lock.unlock()
    }

    func reset() {
        store(.builtIn)
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }
}

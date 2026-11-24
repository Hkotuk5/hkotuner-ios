import BackgroundTasks
import Foundation
import Security
import SwiftUI

struct ListenerProfile: Codable, Equatable {
    var name: String
    var avatar: String?

    var avatarBytes: Data? {
        guard let avatar, avatar.hasPrefix("data:image/"), let comma = avatar.firstIndex(of: ","),
              avatar[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(avatar[avatar.index(after: comma)...]))
    }
}

@MainActor
final class DeviceSync: ObservableObject {
    static let shared = DeviceSync()
    static let refreshID = "uk.hkot.hkotuner.lan-sync"

    @Published private(set) var profile: ListenerProfile?
    @Published private(set) var paired = false
    @Published private(set) var onlineUsername: String?
    @Published private(set) var onlineServer: String?
    @Published private(set) var desktopAddress: DesktopAddress?
    @Published private(set) var syncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var error: String?
    @Published private(set) var remoteListening = ListeningSummary()

    private struct Request: Codable {
        let device: String
        let generation: UInt64
        let base: SharedLibrary
        let library: SharedLibrary
        let baseProfile: ListenerProfile?
        let profile: ListenerProfile?
        let listening: ListeningSummary
    }

    private struct Response: Codable {
        let library: SharedLibrary
        let profile: ListenerProfile?
        let listening: ListeningSummary
    }

    private struct Journal: Codable {
        var device = UUID().uuidString.lowercased()
        var generation: UInt64 = 0
        var server: String?
        var baseline = SharedLibrary()
        var baseProfile: ListenerProfile?
        var lastSync: Date?
        var pending: Request?
        var remoteListening = ListeningSummary()
        var localListening: ListeningSummary?
    }

    private let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    private var journal = Journal()
    private var key: Data?
    private var online: OnlineAccount?
    private var onlineSelected = UserDefaults.standard.bool(forKey: "sync.onlineSelected")
    private var journalURL: URL {
        let name = online.map { "\($0.identity).json" } ?? "lan-sync.json"
        return folder.appendingPathComponent(name)
    }
    private var profileURL: URL { folder.appendingPathComponent("profile.json") }

    private init() {
        profile = load(ListenerProfile.self, from: profileURL)
        if profile == nil, let name = UserDefaults.standard.string(forKey: "profile.name"), !name.isEmpty {
            profile = ListenerProfile(name: name, avatar: nil)
        }
        online = OnlineAccount.load()
        onlineUsername = online?.username
        onlineServer = online?.server.absoluteString
        key = PairingKey.read()
        paired = key != nil
        if let key {
            desktopAddress = UserDefaults.standard.string(forKey: Self.addressKey(key)).flatMap(DesktopAddress.init)
        }
        restoreJournal()
    }

    private func restoreJournal() {
        journal = load(Journal.self, from: journalURL) ?? Journal()
        let label = online?.identity ?? (onlineSelected ? nil : key.map(LanConnection.serviceLabel))
        lastSync = journal.server == label ? journal.lastSync : nil
        remoteListening = journal.server == label ? journal.remoteListening : ListeningSummary()
    }

    func signInOnline(server: String, username: String, password: String) async throws {
        let account = try await OnlineAccount.signIn(server: server, username: username, password: password)
        try Task.checkCancellation()
        try account.save()
        onlineSelected = true
        UserDefaults.standard.set(true, forKey: "sync.onlineSelected")
        setOnline(account)
        schedule()
    }

    func signOutOnline() async throws {
        guard let account = online else { return }
        try OnlineAccount.remove()
        setOnline(nil)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshID)
        try await account.signOut()
    }

    private func setOnline(_ account: OnlineAccount?) {
        online = account
        onlineUsername = account?.username
        onlineServer = account?.server.absoluteString
        restoreJournal()
        error = nil
    }

    func saveProfile(name: String, avatar: String?) throws {
        let visible = name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let cleaned = String(String.UnicodeScalarView(visible.prefix(32)))
        guard !cleaned.isEmpty else { throw HKError("Введи ник") }
        try setProfile(ListenerProfile(name: cleaned, avatar: avatar))
    }

    private func setProfile(_ profile: ListenerProfile) throws {
        try save(profile, to: profileURL)
        self.profile = profile
    }

    func pair(_ text: String, address: String? = nil) throws {
        guard online == nil else { throw HKError("Выйди из онлайн-аккаунта перед подключением к локальной сети") }
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.hasPrefix("hk1."), code.count == 47,
              let bytes = Data(base64Encoded: code.dropFirst(4).replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + "="), bytes.count == 32 else {
            throw HKError("Вставь ключ синхронизации, скопированный в hkotuner на ПК")
        }
        let hint = address.flatMap(DesktopAddress.init)
        if key != bytes {
            try PairingKey.write(bytes)
            key = bytes
            paired = true
            lastSync = nil
            remoteListening = ListeningSummary()
            desktopAddress = UserDefaults.standard.string(forKey: Self.addressKey(bytes)).flatMap(DesktopAddress.init)
        }
        if let hint { setAddress(hint, for: bytes) }
        if onlineSelected {
            onlineSelected = false
            UserDefaults.standard.set(false, forKey: "sync.onlineSelected")
            restoreJournal()
        }
        error = nil
        schedule()
    }

    func saveDesktopAddress(_ text: String) throws {
        guard let key else { return }
        let response = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = DesktopAddress(response)
        guard response.isEmpty || address != nil else { throw HKError("Введи локальный IPv4-адрес и порт из настроек hkotuner на ПК.") }
        setAddress(address, for: key)
        error = nil
    }

    private static func addressKey(_ key: Data) -> String { "lan.address." + LanConnection.serviceLabel(key) }

    private func setAddress(_ address: DesktopAddress?, for key: Data) {
        UserDefaults.standard.set(address?.text, forKey: Self.addressKey(key))
        desktopAddress = address
    }

    func unpair() throws {
        try PairingKey.remove()
        if let key { setAddress(nil, for: key) }
        key = nil
        paired = false
        if online == nil {
            lastSync = nil
            remoteListening = ListeningSummary()
            error = nil
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshID)
        }
    }

    func schedule() {
        guard online != nil || (paired && !onlineSelected) else { return }
        let task = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        task.earliestBeginDate = Date().addingTimeInterval(20 * 60)
        try? BGTaskScheduler.shared.submit(task)
    }

    func sync() async {
        let account = online
        let localKey = onlineSelected ? nil : key
        guard let label = account?.identity ?? localKey.map(LanConnection.serviceLabel), !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            for _ in 0..<2 {
                let library = SharedLibrary(LibraryStore.shared.library)
                var next = journal
                if next.server != label {
                    next = Journal(device: journal.device, generation: journal.generation, server: label)
                }
                let sent: Request
                if let pending = next.pending {
                    sent = pending
                } else {
                    let listening = StatsStore.shared.localListening
                    let changed = next.generation == 0 || next.lastSync == nil || library != next.baseline
                        || profile != next.baseProfile || listening != next.localListening
                    sent = Request(device: next.device, generation: changed ? next.generation + 1 : next.generation,
                                   base: next.baseline, library: library, baseProfile: next.baseProfile,
                                   profile: profile, listening: listening)
                    if changed {
                        next.pending = sent
                        try persist(next)
                    }
                }
                let payload = try JSONEncoder().encode(sent)
                let data: Data
                if let account {
                    data = try await account.exchange(payload)
                } else if let localKey {
                    data = try await LanConnection(key: localKey, address: desktopAddress).send(payload)
                } else { return }
                try Task.checkCancellation()
                guard online == account, account != nil || (!onlineSelected && key == localKey) else { return }
                let reply = try JSONDecoder().decode(Response.self, from: data)
                let current = SharedLibrary(LibraryStore.shared.library)
                let merged = SharedLibrary.merge(base: sent.library, local: reply.library, incoming: current)
                if merged != current { try LibraryStore.shared.applySync(merged) }
                if sent.profile == profile, let updated = reply.profile, updated != profile {
                    try setProfile(updated)
                }
                next.pending = nil
                next.baseline = reply.library
                next.baseProfile = reply.profile
                next.generation = sent.generation
                next.remoteListening = reply.listening
                next.localListening = sent.listening
                next.lastSync = Date()
                try persist(next)
                lastSync = next.lastSync
                if remoteListening != reply.listening { remoteListening = reply.listening }
                error = nil
                if merged == reply.library, profile == reply.profile { break }
            }
        } catch is CancellationError {
        } catch OnlineAccount.Failure.expired {
            guard online == account else { return }
            try? OnlineAccount.remove()
            setOnline(nil)
            self.error = OnlineAccount.Failure.expired.localizedDescription
        } catch {
            guard online == account, account != nil || (!onlineSelected && key == localKey) else { return }
            self.error = error.localizedDescription
        }
    }

    private func persist(_ updated: Journal) throws {
        try save(updated, to: journalURL)
        journal = updated
    }

    private func save<T: Encodable>(_ value: T, to file: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
    }

    private func load<T: Decodable>(_ type: T.Type, from file: URL) -> T? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private enum PairingKey {
        private static let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "uk.hkot.hkotuner.lan-sync",
            kSecAttrAccount as String: "desktop"
        ]

        static func read() -> Data? {
            let options = query.merging([kSecReturnData as String: true]) { _, new in new }
            var value: CFTypeRef?
            guard SecItemCopyMatching(options as CFDictionary, &value) == errSecSuccess else { return nil }
            return value as? Data
        }

        static func write(_ data: Data) throws {
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var attributes = query
                attributes[kSecValueData as String] = data
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                try check(SecItemAdd(attributes as CFDictionary, nil))
            } else { try check(status) }
        }

        static func remove() throws {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
        }

        private static func check(_ status: OSStatus) throws {
            guard status == errSecSuccess else { throw HKError("Не удалось сохранить ключ синхронизации") }
        }
    }
}

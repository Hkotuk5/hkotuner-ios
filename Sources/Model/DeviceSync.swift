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
    private static let guestKey = "sync.continueAsGuest"

    @Published private(set) var profile: ListenerProfile?
    @Published private(set) var paired = false
    @Published private(set) var onlineUsername: String?
    @Published private(set) var needsAccount = true
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
    private var scheduledOnlineSync: Task<Void, Never>?
    private var onlineChangesPending = false
    private var onlineAllowedAt = 0.0
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
        needsAccount = online == nil && !UserDefaults.standard.bool(forKey: Self.guestKey)
        key = PairingKey.read()
        paired = key != nil
        if let key {
            desktopAddress = UserDefaults.standard.string(forKey: Self.addressKey(key)).flatMap(DesktopAddress.init)
        }
        restoreJournal()
    }

    private func restoreJournal() {
        journal = load(Journal.self, from: journalURL) ?? Journal()
        let label = online?.identity ?? key.map(LanConnection.serviceLabel)
        lastSync = journal.server == label ? journal.lastSync : nil
        remoteListening = journal.server == label ? journal.remoteListening : ListeningSummary()
    }

    func authenticateOnline(username: String, password: String, registering: Bool) async throws {
        let account = try await OnlineAccount.authenticate(username: username, password: password, registering: registering)
        try Task.checkCancellation()
        try account.save()
        setOnline(account)
        schedule()
        onlineChanged()
    }

    func signOutOnline() async throws {
        guard let account = online else { return }
        try OnlineAccount.remove()
        returnToSignIn()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshID)
        try await account.signOut()
    }

    func continueAsGuest() {
        guard online == nil else { return }
        UserDefaults.standard.set(true, forKey: Self.guestKey)
        needsAccount = false
        error = nil
        schedule()
    }

    private func returnToSignIn() {
        UserDefaults.standard.set(false, forKey: Self.guestKey)
        setOnline(nil)
    }

    private func setOnline(_ account: OnlineAccount?) {
        scheduledOnlineSync?.cancel()
        scheduledOnlineSync = nil
        onlineChangesPending = false
        onlineAllowedAt = 0
        online = account
        onlineUsername = account?.username
        needsAccount = account == nil
        restoreJournal()
        error = nil
    }

    func saveProfile(name: String, avatar: String?) throws {
        let visible = name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let cleaned = String(String.UnicodeScalarView(visible.prefix(32)))
        guard !cleaned.isEmpty else { throw HKError("Введи ник") }
        let updated = ListenerProfile(name: cleaned, avatar: avatar)
        guard updated != profile else { return }
        try setProfile(updated)
        onlineChanged()
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
        guard !needsAccount, online != nil || paired else { return }
        let task = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        task.earliestBeginDate = Date().addingTimeInterval(20 * 60)
        try? BGTaskScheduler.shared.submit(task)
    }

    func desktopPlayback(_ request: DesktopPlaybackRequest) async throws -> DesktopPlaybackReply {
        guard let account = online else { throw HKError("Войди в онлайн-аккаунт hkotuner.") }
        let reply = try await account.playback(request)
        guard account == online else { throw CancellationError() }
        return reply
    }

    func onlineChanged() {
        guard online != nil else { return }
        onlineChangesPending = true
        scheduleOnlineChanges()
    }

    private func scheduleOnlineChanges() {
        guard online != nil, onlineChangesPending, scheduledOnlineSync == nil, !syncing else { return }
        let delay = max(0.75, onlineAllowedAt - ProcessInfo.processInfo.systemUptime)
        scheduledOnlineSync = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.scheduledOnlineSync = nil
            await self.sync()
        }
    }

    func sync() async {
        let account = online
        let localKey = account == nil ? key : nil
        guard !needsAccount, let label = account?.identity ?? localKey.map(LanConnection.serviceLabel), !syncing else { return }
        if account != nil {
            let now = ProcessInfo.processInfo.systemUptime
            guard now >= onlineAllowedAt else {
                scheduleOnlineChanges()
                return
            }
            scheduledOnlineSync?.cancel()
            scheduledOnlineSync = nil
            onlineChangesPending = false
            onlineAllowedAt = now + 3
        }
        syncing = true
        defer {
            syncing = false
            scheduleOnlineChanges()
        }
        do {
            for _ in 0..<(account == nil ? 2 : 1) {
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
                guard !needsAccount, online == account, account != nil || key == localKey else { return }
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
                if account != nil && (merged != reply.library || profile != reply.profile) { onlineChangesPending = true }
                if merged == reply.library, profile == reply.profile { break }
            }
        } catch is CancellationError {
        } catch OnlineAccount.Failure.expired {
            guard online == account else { return }
            try? OnlineAccount.remove()
            returnToSignIn()
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshID)
            self.error = OnlineAccount.Failure.expired.localizedDescription
        } catch {
            guard !needsAccount, online == account, account != nil || key == localKey else { return }
            if account != nil {
                onlineAllowedAt = ProcessInfo.processInfo.systemUptime + 25
                onlineChangesPending = onlineChangesPending || journal.pending != nil
            }
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

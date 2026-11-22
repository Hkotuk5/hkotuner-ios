import CryptoKit
import Foundation
import Security
import SwiftUI

/// The signed-in YouTube Music account, as the web player itself sends it:
/// the youtube.com cookies and a SAPISIDHASH header made from one of them.
/// The cookies stay in the iOS Keychain on this phone only. It is used for the
/// listener's own likes, playlists and home page — not for getting audio.
enum YTAuth {
    static let origin = "https://music.youtube.com"
    private static let service = "uk.hkot.hkotuner.youtube"
    private static let account = "cookies"

    private static let lock = NSLock()
    private static var loaded = false
    private static var cookie: String?

    /// "NAME=value; NAME2=value2" for youtube.com, or nil when signed out
    static var cookieHeader: String? {
        lock.lock(); defer { lock.unlock() }
        if !loaded {
            cookie = readKeychain()
            loaded = true
        }
        return cookie
    }

    static var isSignedIn: Bool { cookieHeader.flatMap { sapisid(from: $0) } != nil }

    /// the headers of a signed-in request, nil when signed out
    static func headers(now: Date = Date()) -> [String: String]? {
        guard let cookie = cookieHeader, let key = sapisid(from: cookie) else { return nil }
        let time = Int(now.timeIntervalSince1970)
        return [
            "Cookie": cookie,
            "Authorization": "SAPISIDHASH \(time)_\(hash(sapisid: key, time: time, origin: origin))",
            "X-Goog-AuthUser": "0",
            "X-Origin": origin,
        ]
    }

    /// sha1 of "time SAPISID origin", in hex
    static func hash(sapisid: String, time: Int, origin: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data("\(time) \(sapisid) \(origin)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sapisid(from header: String) -> String? {
        var found: [String: String] = [:]
        for part in header.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard let eq = pair.firstIndex(of: "=") else { continue }
            found[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        let value = found["SAPISID"] ?? found["__Secure-3PAPISID"]
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// the youtube.com cookies a finished sign-in left in the web view
    static func header(from cookies: [HTTPCookie]) -> String? {
        let mine = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == "youtube.com" || domain.hasSuffix(".youtube.com")
        }
        var seen = Set<String>()
        var parts: [String] = []
        for cookie in mine where !seen.contains(cookie.name) && !cookie.value.isEmpty {
            seen.insert(cookie.name)
            parts.append("\(cookie.name)=\(cookie.value)")
        }
        let header = parts.joined(separator: "; ")
        return sapisid(from: header) == nil ? nil : header
    }

    @discardableResult
    static func save(_ header: String) -> Bool {
        let data = Data(header.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        lock.lock()
        cookie = ok ? header : nil
        loaded = true
        lock.unlock()
        return ok
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        lock.lock()
        cookie = nil
        loaded = true
        lock.unlock()
    }

    private static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// What the screens know about the account: signed in or not, its name, and
/// bringing its likes and playlists into the library.
@MainActor
final class YTAccount: ObservableObject {
    static let shared = YTAccount()

    @Published private(set) var isSignedIn = YTAuth.isSignedIn
    @Published private(set) var name: String? = UserDefaults.standard.string(forKey: "yt.accountName")
    @Published private(set) var importing: String?
    @Published var note: String?

    var lastImport: Date? { UserDefaults.standard.object(forKey: "yt.lastImport") as? Date }

    func signedIn(with header: String) async -> Bool {
        guard YTAuth.save(header) else {
            note = "Не удалось сохранить вход в связку ключей"
            return false
        }
        isSignedIn = true
        // YouTube's own page (WebPlayer) is signed in with the same account
        WebPlayer.shared.adopt(cookieHeader: header)
        if let found = try? await YTMusic.accountName() {
            name = found
            UserDefaults.standard.set(found, forKey: "yt.accountName")
        }
        HomeFeed.shared.forget()
        return true
    }

    func signOut() {
        YTAuth.clear()
        WebPlayer.shared.signOut()
        isSignedIn = false
        name = nil
        UserDefaults.standard.removeObject(forKey: "yt.accountName")
        UserDefaults.standard.removeObject(forKey: "yt.lastImport")
        HomeFeed.shared.forget()
    }

    /// the account's liked songs and library playlists, added to the library
    func importLibrary(into library: LibraryStore) async {
        guard importing == nil else { return }
        importing = "Читаю понравившиеся…"
        note = nil
        defer { importing = nil }
        do {
            let liked = try await YTMusic.likedSongs()
            importing = "Читаю плейлисты…"
            let cards = try await YTMusic.libraryPlaylists()
            var playlists: [(id: String, name: String, tracks: [Track])] = []
            let wanted = Array(cards.prefix(60))
            for (i, card) in wanted.enumerated() {
                importing = "Плейлист \(i + 1) из \(wanted.count): \(card.title)"
                if let tracks = try? await YTMusic.playlistSongs(card.id, auth: true), !tracks.isEmpty {
                    playlists.append((id: card.id, name: card.title, tracks: tracks))
                }
            }
            let added = library.importAccount(liked: liked, playlists: playlists)
            UserDefaults.standard.set(Date(), forKey: "yt.lastImport")
            note = "Готово: +\(added.liked) любимых, новых плейлистов \(added.created), обновлено \(added.updated)"
        } catch {
            note = error.localizedDescription
        }
    }
}

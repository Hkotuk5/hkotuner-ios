import SwiftUI
import UIKit

@main
struct HkotunerApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var appDelegate
    @StateObject private var player = Player.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var account = YTAccount.shared
    @AppStorage("accent") private var accent = "amber"
    @AppStorage("accent.custom") private var customAccent = "#f0a640"
    @AppStorage("appearance") private var appearance = "dark"
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(account)
                .preferredColorScheme(scheme)
                .tint(Theme.color(accent, custom: customAccent))
                .accentColor(Theme.color(accent, custom: customAccent))
                .task {
                    library.autoBackupIfDue()
                    await ClientConfigStore.shared.refresh()
                    await Updates.shared.checkIfDue()
                }
                .task(id: phase) {
                    guard phase == .active else { return }
                    let sync = DeviceSync.shared
                    sync.schedule()
                    while !Task.isCancelled {
                        await sync.sync()
                        let delay: UInt64 = sync.onlineUsername == nil ? 25_000_000_000 : 10_000_000_000
                        do { try await Task.sleep(nanoseconds: delay) }
                        catch { return }
                    }
                }
                .onReceive(library.sharedChanges) { _ in DeviceSync.shared.onlineChanged() }
                .onReceive(StatsStore.shared.listeningChanges) { _ in DeviceSync.shared.onlineChanged() }
                .onChange(of: phase) { now in
                    if now == .background {
                        player.saveSession()
                        StatsStore.shared.save()
                    } else if now == .active {
                        player.refreshWebPlaybackState()
                    }
                }
        }
        .backgroundTask(.appRefresh(DeviceSync.refreshID)) {
            await DeviceSync.shared.schedule()
            await DeviceSync.shared.sync()
        }
    }

    private var scheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "system": return nil
        default: return .dark
        }
    }
}

enum Theme {
    /// the chosen accent, from the environment (`.tint` / `.accentColor` at the root)
    static var accent: Color { Color.accentColor }

    static let background = dynamic(dark: (0.047, 0.043, 0.039), light: (0.976, 0.965, 0.949))
    static let surface = dynamic(dark: (0.106, 0.100, 0.092), light: (0.925, 0.910, 0.890))
    static let ink = dynamic(dark: (0.953, 0.945, 0.933), light: (0.098, 0.090, 0.082))
    static let muted = dynamic(dark: (0.953, 0.945, 0.933), light: (0.098, 0.090, 0.082), alpha: 0.55)

    static let accents: [(id: String, name: String, color: Color)] = [
        ("amber", "Янтарь", color(0xf0a640)),
        ("red", "Красный", color(0xef4f5a)),
        ("pink", "Розовый", color(0xee6aa7)),
        ("violet", "Фиолетовый", color(0x9d7bf5)),
        ("blue", "Синий", color(0x4f8ef7)),
        ("teal", "Бирюзовый", color(0x2fbfa8)),
        ("green", "Зелёный", color(0x6cc35a)),
    ]

    static func accentID(_ id: String) -> String {
        ["coral": "red", "rose": "pink", "sky": "blue", "mint": "teal"][id] ?? id
    }

    static func color(_ id: String, custom: String) -> Color {
        if id == "custom", let rgb = UInt32(custom.dropFirst(), radix: 16) { return color(rgb) }
        return accents.first(where: { $0.id == accentID(id) })?.color ?? accents[0].color
    }

    static func hex(_ color: Color) -> String? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        let rgb = [red, green, blue].map { Int((max(0, min(1, $0)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", rgb[0], rgb[1], rgb[2])
    }

    private static func color(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 255) / 255,
              green: Double((rgb >> 8) & 255) / 255,
              blue: Double(rgb & 255) / 255)
    }

    private static func dynamic(dark: (Double, Double, Double), light: (Double, Double, Double), alpha: Double = 1) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .light ? light : dark
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: alpha)
        })
    }
}

import SwiftUI
import UIKit

@main
struct HkotunerApp: App {
    @StateObject private var player = Player.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var account = YTAccount.shared
    @AppStorage("accent") private var accent = "amber"
    @AppStorage("appearance") private var appearance = "dark"
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(account)
                .preferredColorScheme(scheme)
                .tint(Theme.color(accent))
                .accentColor(Theme.color(accent))
                .task {
                    library.autoBackupIfDue()
                    await ClientConfigStore.shared.refresh()
                    await Updates.shared.checkIfDue()
                }
                .onChange(of: phase) { now in
                    if now == .background {
                        player.saveSession()
                        StatsStore.shared.save()
                    }
                }
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

    /// the desktop's default accent (#F0A640) and a few others
    static let accents: [(id: String, name: String, color: Color)] = [
        ("amber", "Янтарь", Color(red: 0.941, green: 0.651, blue: 0.251)),
        ("coral", "Коралл", Color(red: 0.965, green: 0.459, blue: 0.392)),
        ("rose", "Роза", Color(red: 0.925, green: 0.451, blue: 0.651)),
        ("violet", "Фиалка", Color(red: 0.639, green: 0.533, blue: 0.976)),
        ("sky", "Небо", Color(red: 0.376, green: 0.698, blue: 0.965)),
        ("mint", "Мята", Color(red: 0.400, green: 0.816, blue: 0.651)),
    ]

    static func color(_ id: String) -> Color {
        accents.first(where: { $0.id == id })?.color ?? accents[0].color
    }

    private static func dynamic(dark: (Double, Double, Double), light: (Double, Double, Double), alpha: Double = 1) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .light ? light : dark
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: alpha)
        })
    }
}

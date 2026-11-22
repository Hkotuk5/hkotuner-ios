import SwiftUI

@main
struct HkotunerApp: App {
    @StateObject private var player = Player.shared
    @StateObject private var library = LibraryStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { await ClientConfigStore.shared.refresh() }
        }
    }
}

enum Theme {
    /// the desktop app's default accent (#F0A640)
    static let accent = Color(red: 0.941, green: 0.651, blue: 0.251)
    static let background = Color(red: 0.047, green: 0.043, blue: 0.039)
    static let surface = Color(red: 0.094, green: 0.090, blue: 0.082)
    static let ink = Color(red: 0.953, green: 0.945, blue: 0.933)
    static let muted = Color(red: 0.953, green: 0.945, blue: 0.933).opacity(0.55)
}

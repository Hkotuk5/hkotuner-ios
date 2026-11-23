import SwiftUI

struct SavedLooksView: View {
    @ObservedObject private var wallpaper = WallpaperStore.shared
    @AppStorage("appearance") private var appearance = "dark"
    @AppStorage("accent") private var accent = "amber"
    @AppStorage("accent.custom") private var customAccent = "#f0a640"
    @State private var naming = false
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Button { name = ""; naming = true } label: {
                    Label("Сохранить текущую тему", systemImage: "plus")
                }
                .disabled(wallpaper.looks.count >= 12)
            }
            ForEach(wallpaper.looks) { look in
                Button {
                    do {
                        try wallpaper.apply(look)
                        customAccent = look.accentHex
                        accent = look.accent
                        appearance = look.appearance
                        error = nil
                    } catch { self.error = error.localizedDescription }
                } label: {
                    Label {
                        Text(look.name)
                    } icon: {
                        Circle().fill(Theme.color(look.accent, custom: look.accentHex))
                            .frame(width: 22, height: 22)
                    }
                }
                .swipeActions {
                    Button("Удалить", role: .destructive) {
                        do { try wallpaper.delete(look) } catch { self.error = error.localizedDescription }
                    }
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        .screenBackground()
        .navigationTitle("Мои темы")
        .alert("Новая тема", isPresented: $naming) {
            TextField("Название", text: $name)
            Button("Сохранить") {
                do { try wallpaper.saveLook(name: name, appearance: appearance, accent: accent, accentHex: customAccent) }
                catch { self.error = error.localizedDescription }
            }
            Button("Отмена", role: .cancel) {}
        }
    }
}

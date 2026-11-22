import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var cacheBytes: Int64 = 0
    @State private var offlineBytes: Int64 = 0
    @State private var downloading: (done: Int, total: Int)?
    @State private var importing = false
    @State private var exportURL: URL?
    @State private var note: String?
    @State private var configChecked: Date?

    var body: some View {
        List {
            Section {
                Toggle("Любимые — без интернета", isOn: Binding(
                    get: { library.offlineLikes },
                    set: { library.offlineLikes = $0 }
                ))
                Button {
                    downloadLiked()
                } label: {
                    if let downloading {
                        Text("Скачиваю \(downloading.done) из \(downloading.total)…")
                    } else {
                        Text("Скачать все любимые сейчас")
                    }
                }
                .disabled(downloading != nil)
                LabeledContent("На телефоне", value: "\(AudioCache.offlineCount()) песен · \(size(offlineBytes))")
            } header: {
                Text("Офлайн")
            } footer: {
                Text("Лайкнутые песни сохраняются в память телефона и играют в метро и самолёте.")
            }

            Section("Кэш") {
                LabeledContent("Недавно игравшие", value: size(cacheBytes))
                Button("Очистить кэш", role: .destructive) {
                    AudioCache.clearCache()
                    measure()
                }
            }

            Section {
                Button("Перенести с компьютера…") { importing = true }
                Button("Сохранить копию библиотеки") {
                    do {
                        exportURL = try library.exportBackup()
                    } catch {
                        note = "Не получилось: \(error.localizedDescription)"
                    }
                }
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Отправить файл", systemImage: "square.and.arrow.up") }
                }
            } header: {
                Text("Библиотека")
            } footer: {
                Text("На компьютере: Настройки → Данные → «Сохранить копию», перекинь файл на телефон (Telegram, iCloud, AirDrop) и выбери его здесь. Любимые и плейлисты добавятся к тем, что уже есть; песни из папок компьютера не переносятся.")
            }

            if let note {
                Text(note).font(.footnote).foregroundStyle(Theme.accent)
            }

            Section {
                LabeledContent("Версия", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                LabeledContent("Клиент YouTube", value: ClientConfigStore.shared.current.players.first?.name ?? "?")
                LabeledContent("Проверено", value: configChecked.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "встроенные")
                Button("Обновить настройки YouTube") {
                    Task {
                        let ok = await ClientConfigStore.shared.refresh()
                        configChecked = ClientConfigStore.shared.lastChecked
                        note = ok ? "Настройки обновлены" : "Не получилось скачать настройки, остались прежние"
                    }
                }
            } header: {
                Text("О приложении")
            } footer: {
                Text("hkotuner для iPhone. Песни ищутся в YouTube Music, звук берётся напрямую с YouTube. SoundCloud пока только на компьютере.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Настройки")
        .onAppear {
            measure()
            configChecked = ClientConfigStore.shared.lastChecked
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard data.count < 64 << 20 else { throw HKError("Файл слишком большой") }
                let added = try library.importDesktop(data)
                note = "Добавлено: \(added.liked) любимых, \(added.playlists) плейлистов"
            } catch {
                note = error.localizedDescription
            }
        }
    }

    private func measure() {
        cacheBytes = AudioCache.bytes(in: AudioCache.cacheDir)
        offlineBytes = AudioCache.bytes(in: AudioCache.offlineDir)
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func downloadLiked() {
        let ids = library.library.liked.compactMap(\.videoId).filter { !AudioCache.isOffline($0) }
        guard !ids.isEmpty else {
            note = "Все любимые уже на телефоне"
            return
        }
        downloading = (0, ids.count)
        Task {
            var failed = 0
            for (i, id) in ids.enumerated() {
                do {
                    try await AudioCache.shared.keepOffline(videoId: id)
                } catch {
                    failed += 1
                }
                downloading = (i + 1, ids.count)
            }
            downloading = nil
            note = failed == 0 ? "Готово" : "Готово, не скачалось: \(failed)"
            measure()
        }
    }
}

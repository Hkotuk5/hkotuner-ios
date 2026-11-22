import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var account: YTAccount
    @ObservedObject private var audio = AudioSettings.shared
    @ObservedObject private var updates = Updates.shared
    @AppStorage("profile.name") private var profileName = ""
    @AppStorage("accent") private var accent = "amber"
    @AppStorage("appearance") private var appearance = "dark"
    @State private var cacheBytes: Int64 = 0
    @State private var offlineBytes: Int64 = 0
    @State private var downloading: (done: Int, total: Int)?
    @State private var importing = false
    @State private var exportURL: URL?
    @State private var note: String?
    @State private var configChecked: Date?
    @State private var signingIn = false
    @State private var confirmSignOut = false
    @AppStorage("web.mode") private var webMode = "auto"
    @AppStorage("web.site") private var webSite = "music"

    var body: some View {
        List {
            Section("Профиль") {
                TextField("Как тебя зовут", text: $profileName)
                    .textInputAutocapitalization(.words)
            }

            accountSection

            webPlayerSection

            Section("Звук") {
                NavigationLink { EqualizerView() } label: {
                    LabeledContent("Эквалайзер", value: audio.eqOn ? audio.presetName : "выключен")
                }
                Toggle("Одинаковая громкость песен", isOn: $audio.normalize)
            }

            Section("Оформление") {
                Picker("Тема", selection: $appearance) {
                    Text("Тёмная").tag("dark")
                    Text("Светлая").tag("light")
                    Text("Как в системе").tag("system")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Цвет")
                    HStack(spacing: 12) {
                        ForEach(Theme.accents, id: \.id) { item in
                            Button { accent = item.id } label: {
                                Circle()
                                    .fill(item.color)
                                    .frame(width: 32, height: 32)
                                    .overlay(Circle().stroke(Theme.ink, lineWidth: accent == item.id ? 3 : 0).padding(-4))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.name)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

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
                LabeledContent("На телефоне", value: "\(songsText(AudioCache.offlineCount())) · \(size(offlineBytes))")
                LabeledContent("Кэш недавних", value: size(cacheBytes))
                Button("Очистить кэш", role: .destructive) {
                    AudioCache.clearCache()
                    measure()
                }
            } header: {
                Text("Офлайн")
            } footer: {
                Text("Лайкнутые песни сохраняются в память телефона и играют в метро и самолёте — и когда YouTube капризничает.")
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
                Toggle("Копия раз в неделю", isOn: Binding(get: { library.autoBackup }, set: { library.autoBackup = $0 }))
            } header: {
                Text("Библиотека")
            } footer: {
                Text("На компьютере: Настройки → Данные → «Сохранить копию», перекинь файл на телефон и выбери его здесь. Еженедельные копии лежат в Файлы → На iPhone → hkotuner → Backups\(library.lastAutoBackup.map { ", последняя " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "").")
            }

            if let note {
                Text(note).font(.footnote).foregroundStyle(Theme.accent)
            }

            Section {
                LabeledContent("Версия", value: Updates.current)
                if updates.hasUpdate, let latest = updates.latest, let page = updates.page {
                    Link(destination: page) {
                        Label("Есть версия \(latest) — открыть", systemImage: "arrow.down.app.fill")
                    }
                } else {
                    Button(updates.checking ? "Проверяю…" : "Проверить обновления") { Task { await updates.check() } }
                        .disabled(updates.checking)
                }
                LabeledContent("Клиент YouTube", value: ClientConfigStore.shared.current.players.first?.name ?? "?")
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
                Text("hkotuner для iPhone. Песни ищутся в YouTube Music, звук берётся напрямую с YouTube, тексты — из LRCLIB. Новая версия ставится так же, как первая: скачай .ipa и установи через Sideloadly или SideStore поверх старой — библиотека останется.")
            }
        }
        .screenBackground()
        .navigationTitle("Настройки")
        .onAppear {
            measure()
            configChecked = ClientConfigStore.shared.lastChecked
        }
        .sheet(isPresented: $signingIn) { SignInView() }
        .confirmationDialog("Выйти из YouTube Music?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) { account.signOut() }
        } message: {
            Text("Перенесённые лайки и плейлисты останутся в библиотеке.")
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

    /// YouTube's own page, for songs YouTube will not hand to the app
    private var webPlayerSection: some View {
        Section {
            Picker("Когда играть через YouTube", selection: $webMode) {
                Text("Если YouTube отказал").tag("auto")
                Text("Всегда").tag("always")
                Text("Никогда").tag("off")
            }
            Picker("Сайт", selection: $webSite) {
                Text("YouTube Music").tag("music")
                Text("YouTube").tag("youtube")
            }
            NavigationLink {
                WebPlayerPage()
            } label: {
                Label("Открыть плеер YouTube", systemImage: "play.rectangle")
            }
            Button("Выйти на странице YouTube", role: .destructive) { WebPlayer.shared.signOut() }
        } header: {
            Text("Плеер YouTube")
        } footer: {
            Text("Когда YouTube просит подтвердить, что ты не бот, песня играет на его странице. Открой плеер, чтобы войти в аккаунт или пройти проверку. В этом режиме недоступны эквалайзер и скачивание, возможна реклама. При сворачивании приложения или блокировке экрана YouTube может поставить песню на паузу. Чтобы продолжить, вернись в приложение и нажми «Играть».")
        }
    }

    @ViewBuilder private var accountSection: some View {
        Section {
            if account.isSignedIn {
                LabeledContent("Аккаунт", value: account.name ?? "YouTube Music")
                Button {
                    Task { await account.importLibrary(into: library) }
                } label: {
                    if let importing = account.importing {
                        HStack { ProgressView(); Text(importing).lineLimit(1) }
                    } else {
                        Text("Перенести лайки и плейлисты")
                    }
                }
                .disabled(account.importing != nil)
                Button("Выйти", role: .destructive) { confirmSignOut = true }
            } else {
                Button { signingIn = true } label: {
                    Label("Войти в YouTube Music", systemImage: "person.crop.circle.badge.plus")
                }
            }
            if let note = account.note {
                Text(note).font(.footnote).foregroundStyle(Theme.accent)
            }
        } header: {
            Text("YouTube Music")
        } footer: {
            Text(account.isSignedIn
                 ? "Вход нужен для твоих лайков, плейлистов и личных подборок на главной\(account.lastImport.map { ". Последний перенос: " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""). Песни играют как и раньше."
                 : "Необязательно. С входом на главной будут твои подборки, а лайки и плейлисты аккаунта можно перенести сюда. Пароль вводится на странице Google, приложение его не видит.")
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
                    // a bot check stops every download: no point asking 500 times
                    if error is BotCheckError {
                        note = error.localizedDescription
                        break
                    }
                }
                downloading = (i + 1, ids.count)
            }
            downloading = nil
            if note == nil || failed == 0 { note = failed == 0 ? "Готово" : "Готово, не скачалось: \(failed)" }
            measure()
        }
    }
}

/// Ten bands, dragged up and down, and the desktop's presets.
struct EqualizerView: View {
    @ObservedObject private var audio = AudioSettings.shared
    @EnvironmentObject private var player: Player

    var body: some View {
        List {
            Section {
                Toggle("Эквалайзер", isOn: $audio.eqOn)
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(0..<10, id: \.self) { band in
                        EQBand(value: audio.gains[band], label: Self.label(AudioSettings.bands[band])) { audio.setGain(band, $0) }
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 220)
                .padding(.vertical, 8)
                .opacity(audio.eqOn ? 1 : 0.4)
                .disabled(!audio.eqOn)
                .listRowBackground(Color.clear)
            } footer: {
                if !player.throughEngine && player.current != nil {
                    Text("Эта песня играет потоком, эквалайзер включится со следующей скачанной.")
                }
            }
            Section("Пресеты") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AudioSettings.presets, id: \.id) { preset in
                            Button { audio.choose(preset.id) } label: {
                                Text(preset.name)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(audio.preset == preset.id ? Theme.accent : Theme.surface))
                                    .foregroundStyle(audio.preset == preset.id ? .black : Theme.ink)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.clear)
            }
        }
        .screenBackground()
        .navigationTitle("Эквалайзер")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func label(_ hz: Double) -> String {
        hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
    }
}

/// one band: a line with a knob, -12…+12 dB
struct EQBand: View {
    let value: Double
    let label: String
    let onChange: (Double) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(value == 0 ? "0" : String(format: "%+.0f", value))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.muted)
            GeometryReader { geo in
                let h = geo.size.height
                let y = h / 2 - CGFloat(value / AudioSettings.gainMax) * (h / 2)
                ZStack(alignment: .top) {
                    Capsule().fill(Theme.surface).frame(width: 6)
                        .frame(maxWidth: .infinity)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 6, height: abs(y - h / 2))
                        .offset(y: min(y, h / 2))
                        .frame(maxWidth: .infinity)
                    Circle()
                        .fill(Theme.ink)
                        .frame(width: 22, height: 22)
                        .shadow(radius: 2)
                        .offset(y: y - 11)
                        .frame(maxWidth: .infinity)
                }
                .contentShape(Rectangle())
                .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let clamped = min(max(drag.location.y, 0), h)
                    onChange(Double((h / 2 - clamped) / (h / 2)) * AudioSettings.gainMax)
                })
            }
            Text(label).font(.caption2).foregroundStyle(Theme.muted)
        }
    }
}

/// the hidden YouTube page on screen: sign in or answer YouTube here
struct WebPlayerPage: View {
    var body: some View {
        WebPlayerScreen()
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Плеер YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { WebPlayer.shared.reloadHome() } label: { Image(systemName: "house") }
                        .accessibilityLabel("На главную YouTube")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Text("Это настоящая страница YouTube. Войди в аккаунт или пройди проверку — потом песни из приложения будут играть здесь.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
    }
}

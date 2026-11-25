import SwiftUI

struct OnlineAccountView: View {
    private let startScreen: Bool
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sync = DeviceSync.shared
    @State private var username = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var registering = false
    @State private var working = false
    @State private var note: String?

    init(startScreen: Bool = false) {
        self.startScreen = startScreen
    }

    var body: some View {
        List {
            if let current = sync.onlineUsername {
                Section {
                    LabeledContent("Аккаунт", value: current)
                    if sync.syncing {
                        ProgressView("Синхронизация…")
                    } else if let last = sync.lastSync {
                        LabeledContent("Последний обмен", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button("Выйти", role: .destructive) { signOut() }
                        .disabled(working)
                }
            } else {
                Section {
                    TextField("Логин", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Пароль", text: $password)
                        .textContentType(registering ? .newPassword : .password)
                        .onSubmit { submit() }
                    if registering {
                        SecureField("Повтори пароль", text: $confirmation)
                            .textContentType(.newPassword)
                            .onSubmit { submit() }
                    }
                    Button(working ? "Подожди…" : (registering ? "Создать аккаунт" : "Войти")) { submit() }
                        .disabled(!canSubmit)
                    Button(registering ? "Уже есть аккаунт" : "Создать аккаунт") { switchForm() }
                        .disabled(working)
                } footer: {
                    Text(registering ? "Пароль от 12 символов. Аккаунт синхронизирует медиатеку через интернет."
                        : "При входе локальная медиатека, профиль и итоги объединятся с данными аккаунта.")
                }
                Section {
                    Button("Продолжить без входа") {
                        sync.continueAsGuest()
                        if !startScreen { dismiss() }
                    }
                        .disabled(working)
                } footer: {
                    Text("Локальная медиатека и синхронизация по Wi-Fi доступны без аккаунта.")
                }
            }
            if let message = note ?? sync.error {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(startScreen ? "hkotuner" : "Онлайн-аккаунт")
        .onAppear {
            if let current = sync.onlineUsername { username = current }
        }
    }

    private var canSubmit: Bool {
        !working && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
            && (!registering || !confirmation.isEmpty)
    }

    private func switchForm() {
        registering.toggle()
        password = ""
        confirmation = ""
        note = nil
    }

    private func submit() {
        guard canSubmit else { return }
        if registering && password != confirmation {
            note = "Пароли не совпадают"
            return
        }
        working = true
        note = nil
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let supplied = password
        let creating = registering
        password = ""
        confirmation = ""
        Task {
            defer { working = false }
            do {
                try await sync.authenticateOnline(username: name, password: supplied, registering: creating)
                registering = false
                await sync.sync()
            } catch { note = error.localizedDescription }
        }
    }

    private func signOut() {
        working = true
        note = nil
        Task {
            defer { working = false }
            do { try await sync.signOutOnline() }
            catch { note = error.localizedDescription }
        }
    }
}

import SwiftUI

struct OnlineAccountView: View {
    @ObservedObject private var sync = DeviceSync.shared
    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    @State private var note: String?

    var body: some View {
        List {
            if let current = sync.onlineUsername {
                Section {
                    LabeledContent("Аккаунт", value: current)
                    if let address = sync.onlineServer { LabeledContent("Сервер", value: address) }
                    if let last = sync.lastSync {
                        LabeledContent("Последний обмен", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button(sync.syncing ? "Синхронизация…" : "Синхронизировать сейчас") {
                        Task { await sync.sync() }
                    }
                    .disabled(sync.syncing || working)
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
                        .textContentType(.password)
                        .onSubmit { signIn() }
                    Button(working ? "Вход…" : "Войти") { signIn() }
                        .disabled(!canSignIn)
                } footer: {
                    Text("После входа hkotuner объединит любимые песни, плейлисты, профиль и итоги с данными этого аккаунта на сервере.")
                }
            }
            if let message = note ?? sync.error {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Онлайн-аккаунт")
        .onAppear {
            if let current = sync.onlineUsername { username = current }
        }
    }

    private var canSignIn: Bool { !working && !username.isEmpty && !password.isEmpty }

    private func signIn() {
        guard canSignIn else { return }
        working = true
        note = nil
        let supplied = password
        password = ""
        Task {
            defer { working = false }
            do {
                try await sync.signInOnline(username: username, password: supplied)
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

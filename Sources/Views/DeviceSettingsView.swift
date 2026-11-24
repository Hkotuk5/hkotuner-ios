import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ListenerAvatar: View {
    let profile: ListenerProfile?
    let fallback: String
    let size: CGFloat

    var body: some View {
        Circle().fill(Theme.accent.opacity(0.18))
            .overlay {
                if let bytes = profile?.avatarBytes {
                    MotionImage(data: bytes)
                } else {
                    Text(fallback).font(.headline.weight(.bold)).foregroundStyle(Theme.accent)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}

struct ListenerProfileSettings: View {
    @ObservedObject private var sync = DeviceSync.shared
    @State private var name = ""
    @State private var choosing = false
    @State private var note: String?

    var body: some View {
        HStack(spacing: 14) {
            ListenerAvatar(profile: sync.profile, fallback: name.first.map { String($0).uppercased() } ?? "♪", size: 48)
            TextField("Ник", text: $name)
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .onSubmit { saveName() }
            Button("Сохранить") { saveName() }
                .buttonStyle(.borderless)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == sync.profile?.name)
        }
            .onAppear { name = sync.profile?.name ?? "" }
            .onChange(of: sync.profile?.name) { name = $0 ?? "" }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) { result in
                do {
                    let image = try Self.avatar(from: result.get())
                    try sync.saveProfile(name: name, avatar: image)
                    note = nil
                } catch { note = error.localizedDescription }
            }
        Button { choosing = true } label: { Label("Выбрать аватар…", systemImage: "person.crop.circle") }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if sync.profile?.avatar != nil {
            Button("Убрать аватар", role: .destructive) {
                do { try sync.saveProfile(name: name, avatar: nil) }
                catch { note = error.localizedDescription }
            }
        }
        if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }


    }

    private func saveName() {
        do {
            try sync.saveProfile(name: name, avatar: sync.profile?.avatar)
            note = nil
        } catch { note = error.localizedDescription }
    }

    private static func avatar(from url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20_000_000 else {
            throw HKError("Выбери изображение до 20 МБ")
        }
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw HKError("Не удалось открыть изображение")
        }
        if CGImageSourceGetType(source) as String? == "com.compuserve.gif" {
            let result = "data:image/gif;base64," + data.base64EncodedString()
            guard result.utf8.count <= 6 * 1024 * 1024 else { throw HKError("GIF для аватара должен быть меньше 4,5 МБ") }
            return result
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256
        ] as [CFString: Any]
        guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let jpeg = UIImage(cgImage: small).jpegData(compressionQuality: 0.85) else {
            throw HKError("Не удалось подготовить аватар")
        }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }
}

struct DeviceSettingsView: View {
    @ObservedObject private var sync = DeviceSync.shared
    @State private var code = ""
    @State private var address = ""
    @State private var note: String?

    var body: some View {
        List {
            Section {
                if sync.paired {
                    if let last = sync.lastSync {
                        LabeledContent("Последний обмен", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button(sync.syncing ? "Синхронизация…" : "Синхронизировать сейчас") {
                        Task { await sync.sync() }
                    }
                    .disabled(sync.syncing)
                    Button("Отключить на iPhone", role: .destructive) {
                        do { try sync.unpair(); note = nil } catch { note = error.localizedDescription }
                    }
                } else {
                    SecureField("Ключ с компьютера", text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Подключить компьютер") {
                        do {
                            try sync.pair(code)
                            code = ""
                            note = nil
                            Task { await sync.sync() }
                        } catch { note = error.localizedDescription }
                    }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let message = note ?? sync.error {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                if sync.paired {
                    Text("Когда hkotuner открыт на ПК, приложения обмениваются любимыми песнями, плейлистами, профилем и годовыми итогами по Wi-Fi.")
                } else {
                    Text("На ПК открой настройки профиля и покажи QR-код или скопируй ключ. Затем подключи iPhone к той же сети.")
                }
            }
            if sync.paired {
                Section {
                    TextField("Адрес ПК", text: $address, prompt: Text("192.168.1.20:48627"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                        .keyboardType(.numbersAndPunctuation)
                        .submitLabel(.done)
                        .onSubmit { saveAddress() }
                    if address != (sync.desktopAddress?.text ?? "") {
                        Button("Сохранить адрес") { saveAddress() }
                    }
                } footer: {
                    Text("Адрес указан в настройках профиля hkotuner на ПК. При смене адреса приложение попробует найти ПК автоматически.")
                }
            }
        }
        .navigationTitle("Синхронизация")
        .onAppear { address = sync.desktopAddress?.text ?? "" }
        .onChange(of: sync.desktopAddress) { address = $0?.text ?? "" }
    }

    private func saveAddress() {
        do {
            try sync.saveDesktopAddress(address)
            address = sync.desktopAddress?.text ?? ""
            note = nil
            Task { await sync.sync() }
        } catch { note = error.localizedDescription }
    }
}

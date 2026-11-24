import AVFAudio
import AVKit
import SwiftUI

struct PlaybackDevicePicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: Player
    @ObservedObject private var sync = DeviceSync.shared
    @State private var outputs = Self.outputs()
    @State private var computers: [DesktopPlaybackDevice] = []
    @State private var checking = true
    @State private var switching = false
    @State private var error: String?
    @State private var connectionError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Аудиовыход iPhone") {
                    HStack(spacing: 12) {
                        Label(outputs, systemImage: "iphone")
                        Spacer()
                        SystemAudioRoutes()
                            .frame(width: 44, height: 44)
                            .accessibilityLabel("Выбрать аудиовыход iPhone")
                    }
                    if player.desktop != nil {
                        Button("Продолжить на iPhone") {
                            change { try await player.continueOnPhone() }
                        }
                    }
                }

                Section {
                    if sync.onlineUsername == nil {
                        NavigationLink("Войти в аккаунт hkotuner") { OnlineAccountView() }
                    } else if checking {
                        ProgressView("Ищем компьютеры…")
                    } else {
                        ForEach(computers) { computer in
                            Button {
                                change { try await player.listen(on: computer) }
                            } label: {
                                HStack {
                                    Label(computer.name, systemImage: "desktopcomputer")
                                    Spacer()
                                    if player.desktop?.id == computer.id {
                                        Image(systemName: "checkmark")
                                            .accessibilityLabel("Выбран")
                                    }
                                }
                            }
                            .disabled(player.desktop?.id == computer.id)
                        }
                        if let connectionError {
                            Text(connectionError).foregroundStyle(.secondary)
                        } else if computers.isEmpty {
                            Text("Компьютеры сейчас не в сети").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Компьютеры")
                } footer: {
                    Text("Чтобы появился ПК, открой hkotuner на компьютере и войди в тот же онлайн-аккаунт.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .disabled(switching)
            .navigationTitle("Устройства")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if switching { ProgressView() }
                    else { Button("Готово") { dismiss() } }
                }
            }
        }
        .interactiveDismissDisabled(switching)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            outputs = Self.outputs()
        }
        .task(id: sync.onlineUsername) { await discoverComputers() }
    }

    private static func outputs() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { port in
            port.portType == .builtInSpeaker || port.portType == .builtInReceiver ? "iPhone" : port.portName
        }
        return outputs.isEmpty ? "iPhone" : outputs.joined(separator: ", ")
    }

    private func discoverComputers() async {
        computers = []
        connectionError = nil
        guard sync.onlineUsername != nil else { return }
        checking = true
        while !Task.isCancelled {
            do {
                let reply = try await sync.desktopPlayback(.devices)
                guard !Task.isCancelled else { return }
                computers = reply.devices ?? []
                connectionError = nil
            } catch {
                guard !Task.isCancelled else { return }
                connectionError = error.localizedDescription
                computers = []
            }
            checking = false
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
    }

    private func change(_ action: @escaping @MainActor () async throws -> Void) {
        switching = true
        error = nil
        Task {
            defer { switching = false }
            do { try await action() }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct SystemAudioRoutes: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        picker.tintColor = UIColor(Theme.ink)
        picker.activeTintColor = UIColor(Theme.accent)
    }
}

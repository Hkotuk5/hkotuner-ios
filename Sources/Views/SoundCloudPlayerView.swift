import AVFoundation
import SwiftUI
import WebKit

struct SoundCloudPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    let embed: SoundCloudEmbed
    @State private var playerURL: URL?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let playerURL {
                    SoundCloudWidget(url: playerURL)
                        .frame(height: 400)
                } else if let error {
                    EmptyNote(icon: "exclamationmark.triangle", title: "Не удалось открыть SoundCloud", text: error)
                } else {
                    ProgressView("Загружаю плеер SoundCloud…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .screenBackground()
            .navigationTitle("SoundCloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
            }
        }
        .task {
            do {
                playerURL = try await embed.loadPlayerURL()
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}

private struct SoundCloudWidget: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        try? AVAudioSession.sharedInstance().setActive(true)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: ()) {
        view.stopLoading()
        view.pauseAllMediaPlayback(completionHandler: nil)
    }
}

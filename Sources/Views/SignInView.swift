import SwiftUI
import WebKit

/// Google's own sign-in page for YouTube Music. The listener types the
/// password there; the app only keeps the youtube.com cookies it leaves
/// (YTAuth, in the Keychain). The page runs in a private web view that
/// forgets everything when it closes.
struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: YTAccount
    @State private var loading = true
    @State private var finishing = false
    @State private var reload = 0

    var body: some View {
        NavigationStack {
            ZStack {
                GoogleWebView(loading: $loading, onSignedIn: finish)
                    .id(reload)
                if finishing {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Вхожу…").font(.subheadline)
                    }
                    .padding(24)
                    .glassCard(radius: 18)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text("Пароль вводится на странице Google — приложение его не видит. Если Google пишет, что браузер или приложение небезопасны, вход из приложений сейчас закрыт: плейлисты можно перенести по ссылке (Библиотека → +).")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
            .navigationTitle("Вход в YouTube Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if loading {
                        ProgressView()
                    } else {
                        Button { reload += 1 } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Начать заново")
                    }
                }
            }
        }
    }

    private func finish(_ header: String) {
        guard !finishing else { return }
        finishing = true
        Task {
            let ok = await account.signedIn(with: header)
            finishing = false
            if ok {
                await HomeFeed.shared.load(force: true)
                dismiss()
            }
        }
    }
}

struct GoogleWebView: UIViewRepresentable {
    /// the sign-in YouTube Music itself starts, ending on music.youtube.com
    static let start: URL = {
        var next = URLComponents(string: "https://www.youtube.com/signin")!
        next.queryItems = [
            URLQueryItem(name: "action_handle_signin", value: "true"),
            URLQueryItem(name: "app", value: "desktop"),
            URLQueryItem(name: "next", value: "https://music.youtube.com/"),
        ]
        var login = URLComponents(string: "https://accounts.google.com/ServiceLogin")!
        login.queryItems = [
            URLQueryItem(name: "service", value: "youtube"),
            URLQueryItem(name: "passive", value: "true"),
            URLQueryItem(name: "continue", value: next.url!.absoluteString),
        ]
        return login.url!
    }()

    @Binding var loading: Bool
    let onSignedIn: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: Self.start))
        return web
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: GoogleWebView
        private var done = false

        init(_ parent: GoogleWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            check(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
        }

        /// signed in once youtube.com has the account's cookies
        private func check(_ webView: WKWebView) {
            guard !done, let host = webView.url?.host?.lowercased(), host == "youtube.com" || host.hasSuffix(".youtube.com") else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.done, let header = YTAuth.header(from: cookies) else { return }
                self.done = true
                self.parent.onSignedIn(header)
            }
        }
    }
}

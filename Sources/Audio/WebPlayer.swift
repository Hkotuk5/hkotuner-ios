import SwiftUI
import UIKit
import WebKit

/// YouTube's own web player, hidden behind the app. When YouTube will not
/// hand the audio to the app ("confirm you're not a bot"), the song plays on
/// its own page (music.youtube.com or m.youtube.com) in a web view that keeps
/// the listener's sign-in. The app only presses play, pause and seek on the
/// page's <video> and reads where it is; everything else is YouTube's page.
@MainActor
final class WebPlayer: NSObject {
    static let shared = WebPlayer()

    struct State {
        var time: Double
        var duration: Double
        var paused: Bool
        var ad: Bool
    }

    /// "auto": files first, the page when YouTube refuses; "always"; "off"
    static var mode: String { UserDefaults.standard.string(forKey: "web.mode") ?? "auto" }
    /// "music" (music.youtube.com) or "youtube" (m.youtube.com)
    static var site: String { UserDefaults.standard.string(forKey: "web.site") ?? "music" }

    nonisolated static func pageURL(_ videoId: String, site: String) -> URL {
        let host = site == "youtube" ? "https://m.youtube.com" : "https://music.youtube.com"
        return URL(string: "\(host)/watch?v=\(videoId)")!
    }

    nonisolated static func homeURL(site: String) -> URL {
        URL(string: site == "youtube" ? "https://m.youtube.com/" : "https://music.youtube.com/")!
    }

    var onState: ((State) -> Void)?
    var onEnded: (() -> Void)?
    var onError: ((String) -> Void)?

    private(set) lazy var webView: WKWebView = makeWebView()
    private var expected: String?
    private var sawVideo = false
    private var started = false
    private var watchdog: Task<Void, Never>?

    // MARK: playing

    func play(videoId: String, at start: Double?) {
        guard Track.isVideoId(videoId) else {
            onError?("это не трек YouTube")
            return
        }
        park()
        expected = videoId
        sawVideo = false
        started = false
        let seek = start.map { String(format: "%.2f", max(0, $0)) } ?? "null"
        let setup = "window.__hkInit = {expected: '\(videoId)', want: true, seekTo: \(seek)};"
        let scripts = webView.configuration.userContentController
        scripts.removeAllUserScripts()
        scripts.addUserScript(WKUserScript(source: setup + Self.pageScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView.load(URLRequest(url: Self.pageURL(videoId, site: Self.site)))

        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, !Task.isCancelled, self.expected == videoId, !self.started else { return }
            self.onError?(self.sawVideo
                ? "Плеер YouTube не начал играть. Открой его (Настройки → Плеер YouTube) — возможно, там нужно войти или что-то подтвердить."
                : "Страница YouTube не открылась. Открой плеер (Настройки → Плеер YouTube) и посмотри, что там.")
        }
    }

    func setPlaying(_ on: Bool) {
        guard expected != nil else { return }
        run(on
            ? "if (window.__hk) { window.__hk.want = true; window.__hk.endedSent = false; } var v = document.querySelector('video'); if (v) { v.play().catch(function(){}); }"
            : "if (window.__hk) { window.__hk.want = false; } var v = document.querySelector('video'); if (v) { v.pause(); }")
    }

    func refreshPlaybackState() {
        guard expected != nil else { return }
        run("window.__hk?.reportState();")
    }

    func seek(to seconds: Double) {
        guard expected != nil, seconds.isFinite else { return }
        run("if (window.__hk) { window.__hk.endedSent = false; } var v = document.querySelector('video'); if (v) { v.currentTime = \(String(format: "%.2f", max(0, seconds))); }")
    }

    func stop() {
        guard expected != nil else { return }
        expected = nil
        watchdog?.cancel()
        run("if (window.__hk) { window.__hk.want = false; } var v = document.querySelector('video'); if (v) { v.pause(); }")
    }

    private func run(_ js: String) {
        webView.evaluateJavaScript("(function(){ \(js) })();", completionHandler: nil)
    }

    // MARK: where the page lives

    /// behind the app's own screens: in the window (so it may play), out of sight
    func park() {
        guard let window = Self.window else { return }
        if webView.superview !== window {
            webView.removeFromSuperview()
            webView.frame = window.bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.insertSubview(webView, at: 0)
        }
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
    }

    /// on screen, to sign in or answer YouTube
    func show(in host: UIView) {
        webView.removeFromSuperview()
        webView.frame = host.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.alpha = 1
        webView.isUserInteractionEnabled = true
        host.addSubview(webView)
        if webView.url == nil { webView.load(URLRequest(url: Self.homeURL(site: Self.site))) }
    }

    func reloadHome() {
        webView.load(URLRequest(url: Self.homeURL(site: Self.site)))
    }

    private static var window: UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    // MARK: sign-in

    /// the youtube.com cookies of the app's own sign-in, so the page is signed in too
    func adopt(cookieHeader: String) {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in Self.cookies(from: cookieHeader) {
            store.setCookie(cookie)
        }
        UserDefaults.standard.set(true, forKey: "web.cookiesAdopted")
    }

    /// forgets the page's sign-in and everything else it stored
    func signOut() {
        stop()
        let store = webView.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        UserDefaults.standard.removeObject(forKey: "web.cookiesAdopted")
    }

    /// "a=1; b=2" → youtube.com cookies
    nonisolated static func cookies(from header: String, now: Date = Date()) -> [HTTPCookie] {
        header.split(separator: ";").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return HTTPCookie(properties: [
                .domain: ".youtube.com",
                .path: "/",
                .name: parts[0],
                .value: parts[1],
                .secure: "TRUE",
                .expires: now.addingTimeInterval(180 * 24 * 3600),
            ])
        }
    }

    // MARK: the web view

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(MessageProxy(owner: self), name: "hk")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 760), configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        if !UserDefaults.standard.bool(forKey: "web.cookiesAdopted"), let header = YTAuth.cookieHeader {
            let store = config.websiteDataStore.httpCookieStore
            for cookie in Self.cookies(from: header) { store.setCookie(cookie) }
            UserDefaults.standard.set(true, forKey: "web.cookiesAdopted")
        }
        return web
    }

    fileprivate func received(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String, expected != nil else { return }
        switch type {
        case "state":
            guard message["found"] as? Bool == true else { return }
            sawVideo = true
            let state = State(
                time: (message["time"] as? NSNumber)?.doubleValue ?? 0,
                duration: (message["duration"] as? NSNumber)?.doubleValue ?? 0,
                paused: (message["paused"] as? Bool) ?? true,
                ad: (message["ad"] as? Bool) ?? false
            )
            if !state.paused && !state.ad && state.time > 0 {
                started = true
                watchdog?.cancel()
            }
            onState?(state)
        case "ended":
            // still this song: repeat-one seeks back and plays it again
            watchdog?.cancel()
            onEnded?()
        case "error":
            guard !started else { return }
            onError?("YouTube не смог проиграть эту песню на своей странице")
        default:
            break
        }
    }

    /// Starts the selected video, reports its state, and stops at the end of
    /// the song so the app can advance its own queue.
    static let pageScript = """
    (function () {
      if (window.__hk) { return; }
      var init = window.__hkInit || {};
      var hk = window.__hk = { want: !!init.want, expected: init.expected || null, seekTo: init.seekTo, endedSent: false, started: false };
      function post(m) { try { window.webkit.messageHandlers.hk.postMessage(m); } catch (e) {} }
      function video() { return document.querySelector('video'); }
      function currentId() { try { return new URLSearchParams(location.search).get('v'); } catch (e) { return null; } }
      function isAd() { return !!document.querySelector('.ad-showing, .ad-interrupting'); }
      function finish(why) {
        if (hk.endedSent) { return; }
        hk.endedSent = true;
        var v = video(); if (v) { v.pause(); }
        post({ type: 'ended', why: why });
      }
      function hook(v) {
        if (v.__hk) { return; }
        v.__hk = true;
        v.addEventListener('ended', function () { if (!isAd()) { finish('ended'); } });
        v.addEventListener('error', function () { post({ type: 'error', code: v.error ? v.error.code : 0 }); });
      }
      function update(allowAutoplay) {
        var id = currentId();
        if (hk.expected && id && id !== hk.expected) {
          if (hk.started) { finish('moved'); }
          return;
        }
        var v = video();
        if (!v) { post({ type: 'state', found: false }); return; }
        hook(v);
        var ad = isAd();
        var duration = isFinite(v.duration) ? v.duration : 0;
        if (!ad && hk.seekTo !== null && hk.seekTo !== undefined && duration > 0) {
          v.currentTime = hk.seekTo;
          hk.seekTo = null;
        }
        // Retry only while starting a song on a visible page. Once the song
        // starts, the page can pause it without the app requesting play again.
        if (allowAutoplay && hk.want && v.paused && !hk.endedSent && !hk.started && !document.hidden) {
          v.play().catch(function () {});
        }
        if (!hk.want && !v.paused) { v.pause(); }
        if (!v.paused && !ad && v.currentTime > 0) { hk.started = true; }
        post({ type: 'state', found: true, time: v.currentTime || 0, duration: duration, paused: v.paused, ad: ad });
      }
      hk.reportState = function () { update(false); };
      setInterval(function () { update(true); }, 500);
    })();
    """
}

extension WebPlayer: WKNavigationDelegate, WKUIDelegate {
    /// links that want a new window (sign-in) open in place
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard expected != nil, !started else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        onError?("Страница YouTube не открылась: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard expected != nil, !started else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        onError?("Страница YouTube не открылась: \(error.localizedDescription)")
    }
}

/// the content controller keeps its handler alive; this keeps the player out of that cycle
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: WebPlayer?

    init(owner: WebPlayer) {
        self.owner = owner
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { owner?.received(body) }
    }
}

/// the hidden page, brought on screen (Settings → YouTube player)
struct WebPlayerScreen: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .black
        WebPlayer.shared.show(in: host)
        return host
    }

    func updateUIView(_ view: UIView, context: Context) {}

    static func dismantleUIView(_ view: UIView, coordinator: ()) {
        WebPlayer.shared.park()
    }
}

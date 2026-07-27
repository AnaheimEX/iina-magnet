//
//  MikanView.swift
//  IinaMagnet
//
//  Mikan (mikanani.me) browser, reached from the library sidebar below PikPak.
//  Clicking a magnet / .torrent link on the page is intercepted and offered to
//  PikPak: save it as an offline-download task, or save-and-cloud-play (wait
//  for the cloud file to become playable, then open it in iina). Closes the
//  loop: discover on Mikan → store in PikPak → play from the cloud.

import SwiftUI
import WebKit
import OSLog
import AppKit

public struct MikanView: View {
    private static let logger = Logger(subsystem: "iina-magnet", category: "mikan")

    private let onBack: () -> Void
    /// Web-page zoom, sized to the window/display so the page lays out fully and
    /// stays readable (the page reflows at this zoom rather than being shrunk
    /// then magnified by the library window's uniform scale).
    private let pageZoom: CGFloat

    @AppStorage("mikanUserZoom") private var userZoom: Double = 1.25
    @State private var pending: Torrent?
    @State private var busy = false
    @State private var toast: String?
    @StateObject private var navigator = MikanWebNavigator()

    public init(onBack: @escaping () -> Void = {}, pageZoom: CGFloat = 1) {
        self.onBack = onBack
        self.pageZoom = pageZoom
    }

    struct Torrent: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let url: String          // magnet:… or https://…/x.torrent
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(LibraryTokens.sep)
            ZStack {
                MikanWebView(navigator: navigator, pageZoom: pageZoom * CGFloat(userZoom)) { name, url in
                    pending = Torrent(name: name, url: url)
                }
                switch navigator.loadState {
                case .idle, .loading:
                    ProgressView("正在打开蜜柑计划…")
                        .controlSize(.small)
                        .padding(18)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                case .failed(let message):
                    VStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 28)).foregroundStyle(LibraryTokens.warn)
                        Text("蜜柑页面加载失败").font(.system(size: 14, weight: .semibold))
                        Text(message).font(.system(size: 11)).foregroundStyle(LibraryTokens.text2)
                            .multilineTextAlignment(.center).frame(maxWidth: 420)
                        Button("重新加载") { navigator.retryHome() }.controlSize(.small)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                case .loaded:
                    EmptyView()
                }
            }
        }
        .background(LibraryTokens.bg)
        .overlay(alignment: .bottom) { if let toast { toastBar(toast) } }
        .sheet(item: $pending) { torrent in actionSheet(torrent) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 3) { Image(systemName: "chevron.left"); Text("媒体库") }
                    .font(.system(size: 12))
            }.buttonStyle(.plain).foregroundStyle(LibraryTokens.text2)
            HStack(spacing: 6) {
                Image(systemName: "leaf.fill").foregroundStyle(LibraryTokens.accent)
                Text("蜜柑计划").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LibraryTokens.text)
            }
            navButtons
            Divider().frame(height: 14).padding(.horizontal, 4)
            zoomControls
            Spacer()
            Text("点击磁力 / 种子可保存到 PikPak").font(.system(size: 11))
                .foregroundStyle(LibraryTokens.text3)
        }
        .padding(.horizontal, 14)
        .frame(height: LibraryTokens.Spacing.toolbarHeight)
        .background(.ultraThinMaterial)
    }

    private var navButtons: some View {
        HStack(spacing: 12) {
            navButton("chevron.backward", help: "后退", enabled: navigator.canGoBack) { navigator.goBack() }
            navButton("chevron.forward", help: "前进", enabled: navigator.canGoForward) { navigator.goForward() }
            navButton("arrow.clockwise", help: "刷新", enabled: navigator.isReady) { navigator.reload() }
            navButton("house", help: "蜜柑首页", enabled: navigator.isReady) { navigator.goHome() }
            navButton("person.crop.circle.badge.xmark", help: "重置蜜柑登录状态",
                      enabled: navigator.isReady) {
                Task {
                    await MikanWebViewStore.shared.resetLoginState()
                    showToast("已清除蜜柑登录状态，请重新登录")
                }
            }
        }
        .padding(.leading, 6)
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            navButton("minus.magnifyingglass", help: "缩小网页") { userZoom = max(userZoom - 0.1, 0.5) }
            Text("\(Int(userZoom * 100))%")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(LibraryTokens.text2)
                .frame(width: 36, alignment: .center)
                .contentShape(Rectangle())
                .onTapGesture { userZoom = 1.0 }
                .help("恢复默认自适应大小")
            navButton("plus.magnifyingglass", help: "放大网页") { userZoom = min(userZoom + 0.1, 3.0) }
        }
    }

    private func navButton(_ icon: String, help: String, enabled: Bool = true,
                           _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12)) }
            .buttonStyle(.plain)
            .foregroundStyle(enabled ? LibraryTokens.text2 : LibraryTokens.text3.opacity(0.5))
            .disabled(!enabled)
            .help(help)
    }

    // MARK: Action sheet

    private func actionSheet(_ torrent: Torrent) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 36))
                .foregroundStyle(LibraryTokens.accent)
            Text("保存到 PikPak").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LibraryTokens.text)
            Text(torrent.name.isEmpty ? "种子任务（由 PikPak 自动命名）" : torrent.name)
                .font(.system(size: 12)).foregroundStyle(LibraryTokens.text2)
                .lineLimit(3).multilineTextAlignment(.center).frame(maxWidth: 360)

            if busy {
                ProgressView().controlSize(.small)
                Text("正在处理…").font(.system(size: 11)).foregroundStyle(LibraryTokens.text3)
            } else {
                HStack(spacing: 10) {
                    Button("仅保存到网盘") { run(torrent, play: false) }
                        .buttonStyle(.bordered)
                    Button("保存并云播") { run(torrent, play: true) }
                        .buttonStyle(.borderedProminent).tint(LibraryTokens.accent)
                }
                Button("取消") { pending = nil }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(LibraryTokens.text3)
            }
        }
        .padding(28).frame(width: 420)
    }

    private func toastBar(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(LibraryTokens.text)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Actions

    private func run(_ torrent: Torrent, play: Bool) {
        Task {
            guard await PikPakAuth.shared.isSignedIn else {
                pending = nil
                showToast("请先在「PikPak 网盘」登录后再保存")
                return
            }
            busy = true
            defer { busy = false; pending = nil }
            do {
                // Name the save with the episode's release title scraped from the
                // row (e.g. "[字幕组][番名][第N集]…"). Mikan magnets carry no `dn`,
                // so without this PikPak can't name a magnet task meaningfully.
                let task = try await PikPakDrive.shared.offlineDownload(url: torrent.url, name: torrent.name)
                Self.logger.info("offline task added: \(task.id, privacy: .public)")
                if play, !task.fileID.isEmpty {
                    showToast("已添加，正在 PikPak 缓存以便流畅播放…")
                    // Wait for the streaming link (the same fast path the drive
                    // browser plays) so cloud-play isn't the slow raw download URL.
                    let url = try await PikPakDrive.shared.waitForStreamablePlaybackURL(fileID: task.fileID)
                    IinaBridgeRegistry.bridge?.openForPlayback(url, options: PlaybackOptions(
                        userAgent: PikPakConfig.web.userAgent, enlargeNetworkCache: true))
                    showToast("已在 IINA 中开始播放")
                } else {
                    showToast("已添加到 PikPak 离线下载，完成后可在网盘播放")
                }
            } catch {
                showToast((error as? PikPakError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            withAnimation { if toast == text { toast = nil } }
        }
    }
}

// MARK: - Title cleanup

/// Normalizes a title captured from the Mikan page DOM (a table cell's text)
/// into a clean, single-line save name. Pure so it's unit-testable without a
/// web view.
enum MikanTitle {
    static func clean(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Cap length so a stray "select-all" capture can't produce an absurd name.
        return String(collapsed.prefix(300))
    }
}

enum MikanNewWindowDestination: Equatable {
    case currentWebView
    case externalBrowser
    case ignore

    static func resolve(url: URL, sourceHost: String,
                        isUserActivated: Bool = false, isMainFrame: Bool = false) -> Self {
        let scheme = url.scheme?.lowercased()
        let trustedSource = MikanCookieArchive.isSupported(host: sourceHost)
        if scheme == "https", MikanCookieArchive.isSupported(host: url.host ?? "") {
            return .currentWebView
        }
        if trustedSource,
           scheme == "magnet" || (scheme == "https" && url.pathExtension.lowercased() == "torrent") {
            return .currentWebView
        }
        if trustedSource, isUserActivated, isMainFrame,
           scheme == "http" || scheme == "https" { return .externalBrowser }
        return .ignore
    }
}

// MARK: - Web navigation

/// Bridges the SwiftUI nav buttons to the underlying WKWebView: holds a weak
/// reference to it and publishes whether back/forward are available so the
/// buttons enable/disable correctly.
@MainActor
final class MikanWebNavigator: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    static let homeURL = URL(string: "https://mikanani.me/")!

    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published private(set) var isReady = false
    @Published private(set) var loadState: LoadState = .idle
    fileprivate weak var webView: WKWebView?

    func goBack() { if isReady { webView?.goBack() } }
    func goForward() { if isReady { webView?.goForward() } }
    func reload() { if isReady { webView?.reload() } }
    func goHome() { if isReady { webView?.load(URLRequest(url: Self.homeURL)) } }
    func retryHome() {
        setReady(true)
        setLoadState(.loading)
        webView?.load(URLRequest(url: Self.homeURL, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    fileprivate func setReady(_ ready: Bool) {
        guard isReady != ready else { return }
        isReady = ready
        if !ready {
            if canGoBack { canGoBack = false }
            if canGoForward { canGoForward = false }
        }
    }

    fileprivate func sync(_ webView: WKWebView) {
        let nextCanGoBack = webView.canGoBack
        let nextCanGoForward = webView.canGoForward
        if canGoBack != nextCanGoBack { canGoBack = nextCanGoBack }
        if canGoForward != nextCanGoForward { canGoForward = nextCanGoForward }
    }

    fileprivate func setLoadState(_ state: LoadState) {
        guard loadState != state else { return }
        loadState = state
    }
}

// MARK: - Web view

/// Holds the single, persistent Mikan web view so the user's mikanani.me login
/// (and the current page) survives leaving and re-entering the Mikan screen.
/// The screen is shown/hidden by toggling a host `@State` (LibraryWindowView),
/// which would otherwise destroy the web view on every exit and drop a
/// just-completed login until the next reload — the bug where the page reads
/// "not logged in" until you switch pages and come back. The default
/// (persistent) website data store is the primary cookie store. Session cookies
/// are also mirrored to Keychain and restored before the first navigation of a
/// new launch; see `MikanCookiePersistence`.
@MainActor
final class MikanWebViewStore: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
                               WKHTTPCookieStoreObserver {
    static let shared = MikanWebViewStore()
    static let messageName = "mikanTorrent"
    private static let logger = Logger(subsystem: "iina-magnet", category: "mikan-web")

    let webView: WKWebView
    /// Set by the live `MikanWebView` so captured links reach the current view.
    var onCapture: ((_ name: String, _ url: String) -> Void)?
    /// The current view's navigator, which publishes back/forward state.
    weak var navigator: MikanWebNavigator?
    private let cookiePersistence = MikanCookiePersistence()
    private var preparationTask: Task<Void, Never>?
    private var preparationDeadlineTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var isPrepared = false
    private var didStartInitialNavigation = false
    private var currentLoadState: MikanWebNavigator.LoadState = .idle
    private var isObservingCookies = false
    private var isResettingCookies = false

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // primary store; Keychain recovers session cookies
        let controller = WKUserContentController()
        config.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true     // trackpad swipe back/forward
        webView.allowsMagnification = true                     // trackpad pinch to zoom
        self.webView = webView
        super.init()
        controller.add(self, name: Self.messageName)
        controller.addUserScript(WKUserScript(source: MikanWebView.clickScript,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Hydrates any missing cookies before the first request. Later shows keep
    /// the current (possibly logged-in) page instead of resetting to home.
    func prepareAndLoadHomeIfNeeded() {
        if isPrepared {
            navigator?.setReady(true)
            startInitialNavigationIfNeeded()
            return
        }
        guard preparationTask == nil else { return }
        navigator?.setReady(false)

        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        if !isObservingCookies {
            cookieStore.add(self)
            isObservingCookies = true
        }
        publishLoadState(.loading)

        // Cookie recovery improves login persistence, but it must never be a
        // hard dependency for opening the site. If keychain hydration is
        // slow, navigation starts anyway and a later restore still triggers a
        // single safe reload.
        preparationDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            Self.logger.warning("Mikan cookie restore exceeded startup deadline; loading page without blocking")
            self.startInitialNavigationIfNeeded()
        }
        preparationTask = Task { [weak self] in
            guard let self else { return }
            let restoredCount = await cookiePersistence.restoreMissingCookies(into: cookieStore)
            let navigationStartedBeforeRestore = didStartInitialNavigation
            preparationDeadlineTask?.cancel()
            preparationDeadlineTask = nil
            startInitialNavigationIfNeeded()
            if navigationStartedBeforeRestore, restoredCount > 0 {
                Self.logger.info("Reloading Mikan once after late authentication-cookie restore")
                webView.reload()
            }
            preparationTask = nil
            scheduleCookieSnapshot()
        }
    }

    private func startInitialNavigationIfNeeded() {
        isPrepared = true
        navigator?.setReady(true)
        guard !didStartInitialNavigation else { return }
        didStartInitialNavigation = true
        publishLoadState(.loading)
        webView.load(URLRequest(url: MikanWebNavigator.homeURL))
    }

    // Keep the back/forward button state in sync as pages load.
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        publishLoadState(.loading)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { navigator?.sync(webView) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigator?.sync(webView)
        publishLoadState(.loaded)
        scheduleCookieSnapshot()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.logger.error("Mikan navigation failed: \(error.localizedDescription, privacy: .public)")
        publishLoadState(.failed(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        Self.logger.error("Mikan provisional navigation failed: \(error.localizedDescription, privacy: .public)")
        publishLoadState(.failed(error.localizedDescription))
    }

    /// Mikan opens many bangumi/episode links with `target=_blank`. WKWebView
    /// silently drops those without a UI delegate, which made ordinary links
    /// look broken. Keep Mikan and captured torrent links in this view; open an
    /// explicit external web link in the user's browser.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url else { return nil }
        let sourceHost = navigationAction.sourceFrame.securityOrigin.host.isEmpty
            ? webView.url?.host ?? ""
            : navigationAction.sourceFrame.securityOrigin.host
        switch MikanNewWindowDestination.resolve(
            url: url,
            sourceHost: sourceHost,
            isUserActivated: navigationAction.navigationType == .linkActivated,
            isMainFrame: navigationAction.sourceFrame.isMainFrame
        ) {
        case .currentWebView:
            webView.load(navigationAction.request)
        case .externalBrowser:
            NSWorkspace.shared.open(url)
        case .ignore:
            break
        }
        return nil
    }

    private func publishLoadState(_ state: MikanWebNavigator.LoadState) {
        currentLoadState = state
        navigator?.setLoadState(state)
    }

    fileprivate func bind(navigator: MikanWebNavigator,
                          onCapture: @escaping (_ name: String, _ url: String) -> Void) {
        self.navigator = navigator
        self.onCapture = onCapture
        navigator.webView = webView
    }

    /// Publishing from `makeNSView` / `updateNSView` synchronously re-enters
    /// SwiftUI's update transaction. Always call this from a deferred main-actor
    /// task after the representable callback has returned.
    fileprivate func publishBoundNavigatorState() {
        guard let navigator else { return }
        navigator.setReady(isPrepared || didStartInitialNavigation)
        navigator.setLoadState(currentLoadState)
        navigator.sync(webView)
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        guard !isResettingCookies else { return }
        scheduleCookieSnapshot()
    }

 func resetLoginState() async {
     guard isPrepared, !isResettingCookies else { return }
        isResettingCookies = true
        navigator?.setReady(false)
        snapshotTask?.cancel()
        webView.stopLoading()
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        await cookiePersistence.clearAllCookies(from: cookieStore)
        isResettingCookies = false
     webView.load(URLRequest(url: MikanWebNavigator.homeURL))
     navigator?.setReady(true)
 }

  func flushCookieSnapshot() async {
     snapshotTask?.cancel()
     let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
     await cookiePersistence.snapshot(from: cookieStore)
  }

  private func scheduleCookieSnapshot() {
        snapshotTask?.cancel()
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            await cookiePersistence.snapshot(from: cookieStore)
        }
    }

    // Primary path: the injected click listener posts {name, url}.
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName,
              MikanCookieArchive.isSupported(host: message.frameInfo.securityOrigin.host),
              let body = message.body as? [String: Any],
              let url = (body["url"] as? String)?.trimmingCharacters(in: .whitespaces),
              let captureURL = URL(string: url),
              Self.isSupportedCaptureURL(captureURL) else { return }
        onCapture?(MikanTitle.clean(body["name"] as? String ?? ""), url)
    }

    // Fallback: a plain navigation to a magnet / .torrent link (no JS).
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let sourceHost = navigationAction.sourceFrame.securityOrigin.host
        let trustedSource = sourceHost.isEmpty
            ? MikanCookieArchive.isSupported(host: webView.url?.host ?? "")
            : MikanCookieArchive.isSupported(host: sourceHost)
        if url.scheme == "magnet", trustedSource {
            decisionHandler(.cancel)
            // Use the magnet's display name (real title) when present; else leave
            // empty so PikPak names it from the torrent metadata.
            onCapture?(Self.magnetName(url) ?? "", url.absoluteString)
        } else if url.scheme?.lowercased() == "https",
                  url.pathExtension.lowercased() == "torrent", trustedSource {
            decisionHandler(.cancel)
            // A .torrent URL's filename is just the info-hash — not a usable title
            // — so pass no name and let PikPak resolve the real one.
            onCapture?("", url.absoluteString)
        } else {
            decisionHandler(.allow)
        }
    }

    /// The `dn` (display name) parameter of a magnet URI, if present.
    static func magnetName(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "dn" }?.value?.removingPercentEncoding
    }

    private static func isSupportedCaptureURL(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "magnet" { return true }
        return url.scheme?.lowercased() == "https" && url.pathExtension.lowercased() == "torrent"
    }
}

private struct MikanWebView: NSViewRepresentable {
    var navigator: MikanWebNavigator
    var pageZoom: CGFloat
    var onCapture: (_ name: String, _ url: String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let store = MikanWebViewStore.shared
        store.bind(navigator: navigator, onCapture: onCapture)
        store.webView.pageZoom = pageZoom
        Task { @MainActor [weak navigator] in
            guard let navigator, store.navigator === navigator else { return }
            store.publishBoundNavigatorState()
            store.prepareAndLoadHomeIfNeeded()
        }
        return store.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let store = MikanWebViewStore.shared
        store.bind(navigator: navigator, onCapture: onCapture)
        if abs(nsView.pageZoom - pageZoom) > 0.01 { nsView.pageZoom = pageZoom }
    }

    // No dismantleNSView: the store owns the web view across show/hide, so the
    // login session and current page persist instead of being torn down.

    /// Intercepts clicks on magnet / .torrent links — including Mikan's
    /// `data-clipboard-text` magnet buttons, which aren't hrefs so navigation
    /// interception alone would miss them — and reports the link plus the
    /// episode title read from the surrounding table row.
    fileprivate static let clickScript = """
    (function() {
      function titleFor(el) {
        // Mikan's rows aren't a <table>: the release title is an
        // <a class="magnet-link-wrap"> sibling of the magnet / .torrent button.
        // Climb a few ancestors to the row container and read that title — NOT
        // the page's overall bangumi title.
        var node = el;
        for (var i = 0; i < 6 && node; i++) {
          if (node.querySelector) {
            var t = node.querySelector('a.magnet-link-wrap');
            if (t && t.innerText && t.innerText.trim()) return t.innerText.trim();
          }
          node = node.parentElement;
        }
        // Episode detail page fallbacks.
        var header = document.querySelector('.magnet-link-wrap, .episode-title, .bangumi-title, p.bangumi-title');
        if (header && header.innerText && header.innerText.trim()) return header.innerText.trim();
        return (document.title || '').replace(/\\s*[-|]\\s*Mikan.*$/i, '').trim();
      }
      document.addEventListener('click', function(e) {
        var a = e.target.closest('a[data-clipboard-text^="magnet:"], a[href^="magnet:"], a[href$=".torrent"]');
        if (!a) return;
        var url = a.getAttribute('data-clipboard-text') || a.href;
        if (!url) return;
        if (url.indexOf('magnet:') === 0 || /\\.torrent($|\\?)/.test(url)) {
          e.preventDefault();
          window.webkit.messageHandlers.mikanTorrent.postMessage({ name: titleFor(a), url: url });
        }
      }, true);
    })();
    """
}

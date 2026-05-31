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

public struct MikanView: View {
    private static let logger = Logger(subsystem: "iina-magnet", category: "mikan")

    private let onBack: () -> Void
    /// Web-page zoom, sized to the window/display so the page lays out fully and
    /// stays readable (the page reflows at this zoom rather than being shrunk
    /// then magnified by the library window's uniform scale).
    private let pageZoom: CGFloat

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
            MikanWebView(navigator: navigator, pageZoom: pageZoom) { name, url in
                pending = Torrent(name: name, url: url)
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
            navButton("arrow.clockwise", help: "刷新") { navigator.reload() }
            navButton("house", help: "蜜柑首页") { navigator.goHome() }
        }
        .padding(.leading, 6)
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

// MARK: - Web navigation

/// Bridges the SwiftUI nav buttons to the underlying WKWebView: holds a weak
/// reference to it and publishes whether back/forward are available so the
/// buttons enable/disable correctly.
@MainActor
final class MikanWebNavigator: ObservableObject {
    static let homeURL = URL(string: "https://mikanani.me/")!

    @Published var canGoBack = false
    @Published var canGoForward = false
    fileprivate weak var webView: WKWebView?

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func goHome() { webView?.load(URLRequest(url: Self.homeURL)) }

    fileprivate func sync(_ webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
}

// MARK: - Web view

private struct MikanWebView: NSViewRepresentable {
    static let messageName = "mikanTorrent"

    var navigator: MikanWebNavigator
    var pageZoom: CGFloat
    var onCapture: (_ name: String, _ url: String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(navigator: navigator, onCapture: onCapture) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Self.messageName)
        controller.addUserScript(WKUserScript(source: Self.clickScript,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: false))
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true     // trackpad swipe back/forward
        webView.pageZoom = pageZoom
        navigator.webView = webView
        webView.load(URLRequest(url: MikanWebNavigator.homeURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if abs(nsView.pageZoom - pageZoom) > 0.01 { nsView.pageZoom = pageZoom }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: messageName)
    }

    /// Intercepts clicks on magnet / .torrent links — including Mikan's
    /// `data-clipboard-text` magnet buttons, which aren't hrefs so navigation
    /// interception alone would miss them — and reports the link plus the
    /// episode title read from the surrounding table row.
    private static let clickScript = """
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

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let navigator: MikanWebNavigator
        private let onCapture: (_ name: String, _ url: String) -> Void
        init(navigator: MikanWebNavigator,
             onCapture: @escaping (_ name: String, _ url: String) -> Void) {
            self.navigator = navigator
            self.onCapture = onCapture
        }

        // Keep the back/forward button state in sync as pages load.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            navigator.sync(webView)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            navigator.sync(webView)
        }

        // Primary path: the injected click listener posts {name, url}.
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == MikanWebView.messageName,
                  let body = message.body as? [String: Any],
                  let url = (body["url"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !url.isEmpty else { return }
            let name = MikanTitle.clean(body["name"] as? String ?? "")
            onCapture(name, url)
        }

        // Fallback: a plain navigation to a magnet / .torrent link (no JS).
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
            if url.scheme == "magnet" {
                decisionHandler(.cancel)
                // Use the magnet's display name (real title) when present; else
                // leave empty so PikPak names it from the torrent metadata.
                onCapture(Self.magnetName(url) ?? "", url.absoluteString)
            } else if url.pathExtension.lowercased() == "torrent" {
                decisionHandler(.cancel)
                // A .torrent URL's filename is just the info-hash — not a usable
                // title — so pass no name and let PikPak resolve the real one.
                onCapture("", url.absoluteString)
            } else {
                decisionHandler(.allow)
            }
        }

        /// The `dn` (display name) parameter of a magnet URI, if present.
        static func magnetName(_ url: URL) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "dn" }?.value?.removingPercentEncoding
        }
    }
}

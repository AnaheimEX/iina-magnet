//
//  PikPakLoginView.swift
//  IinaMagnet
//
//  The PikPak login sheet: loads the official mypikpak.com page in a web view
//  so PikPak handles captcha / 2FA itself, then reads the resulting auth tokens
//  back out of localStorage (see PikPakWebCredentialParser) and hands them to
//  the caller to adopt as a session. No credentials pass through our code.

import SwiftUI
import WebKit
import OSLog

enum PikPakLoginLoadState: Equatable {
    case loading
    case loaded
    case failed(String)
}

enum PikPakLoginNavigationPolicy {
    private static let allowedNavigationDomains = [
        "mypikpak.com",
        "google.com",
        "googleusercontent.com",
        "facebook.com",
        "apple.com",
    ]

    static func allowsNavigation(to url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }
        return allowedNavigationDomains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    static func isCredentialOrigin(host: String, isMainFrame: Bool) -> Bool {
        isMainFrame && host.lowercased() == "mypikpak.com"
    }
}

/// Sheet chrome (title + cancel) around the login web view.
struct PikPakLoginSheet: View {
    var onCancel: () -> Void
    var onCapture: (PikPakWebCredentials) -> Void
    @State private var loadState: PikPakLoginLoadState = .loading
    @State private var loadAttempt = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消", action: onCancel).buttonStyle(.plain)
                    .foregroundStyle(LibraryTokens.text2)
                Spacer()
                Text("登录 PikPak").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LibraryTokens.text)
                Spacer()
                // Balances the leading button so the title stays centered.
                Text("取消").opacity(0)
            }
            .padding(.horizontal, 14).frame(height: 44)
            .background(.ultraThinMaterial)
            Divider().overlay(LibraryTokens.sep)

            ZStack {
                PikPakLoginWebView(
                    loadAttempt: loadAttempt,
                    onCapture: onCapture,
                    onLoadStateChange: { loadState = $0 }
                )
                // Retry must create a new WKWebView and a new non-persistent
                // data store; reloading the old view would retain its stale
                // localStorage/cookies and could immediately re-adopt them.
                .id(loadAttempt)
                switch loadState {
                case .loading:
                    ProgressView("正在打开 PikPak 官方登录页…")
                        .controlSize(.small)
                        .padding(18)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                case .failed(let message):
                    VStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 28)).foregroundStyle(LibraryTokens.warn)
                        Text("PikPak 登录页加载失败")
                            .font(.system(size: 14, weight: .semibold))
                        Text(message).font(.system(size: 11))
                            .foregroundStyle(LibraryTokens.text2)
                            .multilineTextAlignment(.center).frame(maxWidth: 360)
                        Button("重新加载") {
                            loadState = .loading
                            loadAttempt += 1
                        }
                        .controlSize(.small)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                case .loaded:
                    EmptyView()
                }
            }
        }
        .frame(width: 480, height: 640)
    }
}

/// WKWebView that loads PikPak's login page and reports captured tokens.
struct PikPakLoginWebView: NSViewRepresentable {
    var loadAttempt: Int
    var onCapture: (PikPakWebCredentials) -> Void
    var onLoadStateChange: (PikPakLoginLoadState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onLoadStateChange: onLoadStateChange)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // A login attempt must never inherit stale localStorage/cookies from a
        // previous session. The old persistent store caused its token snapshot
        // to be captured immediately, dismissing the sheet before it appeared.
        config.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.captureJS,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        controller.add(context.coordinator, name: "pikpak")
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        // The current PikPak SPA never leaves its initial loader with WebKit's
        // bare app UA. Its supported Chrome-shaped web-client UA completes and
        // renders the login form, as verified with a native WKWebView probe.
        webView.customUserAgent = PikPakConfig.web.userAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        _ = context.coordinator.beginAttempt(loadAttempt)
        webView.load(URLRequest(url: Self.loginURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if context.coordinator.beginAttempt(loadAttempt) {
            nsView.load(URLRequest(url: Self.loginURL,
                                   cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.cancel()
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "pikpak")
    }

    /// Opening the login route directly avoids booting the full drive SPA merely
    /// to wait for its unauthenticated redirect. The redirect target stays on the
    /// same origin so localStorage token capture continues to work after login.
    static let loginURL: URL = {
        var components = URLComponents(
            url: PikPakConfig.web.webHomeURL.appendingPathComponent("drive/login"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "redirect", value: "/all")]
        return components.url!
    }()

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        private static let logger = Logger(subsystem: "iina-magnet", category: "pikpak-login")
        private let onCapture: (PikPakWebCredentials) -> Void
        private let onLoadStateChange: (PikPakLoginLoadState) -> Void
        private var captured = false
        private var currentAttempt = Int.min
        private var generation = 0
        private var phase: AttemptPhase = .cancelled
        private var loadDeadline: DispatchWorkItem?

        // Latest pieces seen; assembled once tokens + captcha + device align.
        private var lastLocalStorage: String?
        private var capturedCaptcha: String?
        private var capturedDevice: String?
        private var fallbackScheduled = false

        init(onCapture: @escaping (PikPakWebCredentials) -> Void,
             onLoadStateChange: @escaping (PikPakLoginLoadState) -> Void) {
            self.onCapture = onCapture
            self.onLoadStateChange = onLoadStateChange
        }

        func beginAttempt(_ attempt: Int) -> Bool {
            guard currentAttempt != attempt else { return false }
            currentAttempt = attempt
            generation &+= 1
            loadDeadline?.cancel()
            captured = false
            phase = .loading
            lastLocalStorage = nil
            capturedCaptcha = nil
            capturedDevice = nil
            fallbackScheduled = false
            scheduleLoadDeadline(for: generation)
            return true
        }

        func cancel() {
            generation &+= 1
            loadDeadline?.cancel()
            loadDeadline = nil
            phase = .cancelled
            captured = true
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard PikPakLoginNavigationPolicy.isCredentialOrigin(
                host: message.frameInfo.securityOrigin.host,
                isMainFrame: message.frameInfo.isMainFrame
            ) else { return }
            if let json = message.body as? String {              // legacy: bare localStorage
                lastLocalStorage = json
            } else if let dict = message.body as? [String: Any] {
                switch dict["type"] as? String {
                case "ls":  lastLocalStorage = dict["data"] as? String ?? lastLocalStorage
                case "hdr":
                    if let c = (dict["captcha"] as? String)?.nonEmpty { capturedCaptcha = c }
                    if let d = (dict["device"] as? String)?.nonEmpty { capturedDevice = d }
                default: break
                }
            }
            attemptFinish()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkPageReadiness(in: webView, generation: generation, attemptsRemaining: 30)
            guard PikPakLoginNavigationPolicy.isCredentialOrigin(
                host: webView.url?.host ?? "", isMainFrame: true
            ) else { return }
            webView.evaluateJavaScript("JSON.stringify(localStorage)") { [weak self] result, _ in
                guard let self else { return }
                if let json = result as? String { self.lastLocalStorage = json }
                self.attemptFinish()
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            if phase == .loading { onLoadStateChange(.loading) }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // PikPak loads dozens of chunks. A slow analytics resource can hold
            // `didFinish` after the visible login form is already usable, so poll
            // the DOM briefly and uncover the page as soon as real content exists.
            checkPageReadiness(in: webView, generation: generation, attemptsRemaining: 40)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            report(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            report(PikPakError.transport("PikPak 登录页进程意外退出"))
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url,
                  PikPakLoginNavigationPolicy.allowsNavigation(to: url) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        /// OAuth providers commonly use target=_blank/window.open. Keep the
        /// navigation inside this sheet so those buttons do not appear inert.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil,
               let url = navigationAction.request.url,
               PikPakLoginNavigationPolicy.allowsNavigation(to: url) {
                webView.load(navigationAction.request)
            }
            return nil
        }

        private func report(_ error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
            guard phase != .failed, phase != .cancelled else { return }
            Self.logger.error("PikPak login navigation failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed
            generation &+= 1
            loadDeadline?.cancel()
            loadDeadline = nil
            onLoadStateChange(.failed(error.localizedDescription))
        }

        private func scheduleLoadDeadline(for scheduledGeneration: Int) {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == scheduledGeneration, self.phase == .loading else { return }
                self.phase = .failed
                self.generation &+= 1
                self.loadDeadline = nil
                self.onLoadStateChange(.failed("连接 PikPak 超时，请检查网络或代理后重试"))
            }
            loadDeadline = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: work)
        }

        private func checkPageReadiness(in webView: WKWebView, generation expectedGeneration: Int,
                                        attemptsRemaining: Int) {
            guard generation == expectedGeneration, phase == .loading, attemptsRemaining > 0 else { return }
            webView.evaluateJavaScript("""
                (function () {
                  var loader = document.querySelector('#initial-loading');
                  var text = document.body && (document.body.innerText || '').trim();
                  return document.readyState !== 'loading' && !loader &&
                    ((document.title || '').trim().length > 0 || (text && text.length > 20));
                })()
                """) { [weak self, weak webView] result, _ in
                guard let self, let webView,
                      self.generation == expectedGeneration, self.phase == .loading else { return }
                if result as? Bool == true {
                    self.markPagePresented()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak webView] in
                        guard let self, let webView else { return }
                        self.checkPageReadiness(in: webView, generation: expectedGeneration,
                                                attemptsRemaining: attemptsRemaining - 1)
                    }
                }
            }
        }

        private func markPagePresented() {
            guard phase == .loading else { return }
            phase = .presented
            loadDeadline?.cancel()
            loadDeadline = nil
            onLoadStateChange(.loaded)
        }

        private enum AttemptPhase {
            case loading
            case presented
            case failed
            case cancelled
        }

        /// Finishes when we have tokens + a captured captcha token + a device id
        /// (a fully working session). Falls back to tokens-only after a short
        /// grace period if the SPA never makes an API call we can observe.
        private func attemptFinish() {
            guard phase != .failed, phase != .cancelled, !captured,
                  let json = lastLocalStorage,
                  let base = PikPakWebCredentialParser.parse(localStorageJSON: json) else { return }

            let device = capturedDevice ?? base.deviceID
            if let captcha = capturedCaptcha, let device {
                finish(base, device: device, captcha: captcha)
                return
            }
            scheduleFallback(json)
        }

        private func scheduleFallback(_ json: String) {
            guard !fallbackScheduled else { return }
            fallbackScheduled = true
            let scheduledGeneration = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.generation == scheduledGeneration, !self.captured,
                      let base = PikPakWebCredentialParser.parse(localStorageJSON: self.lastLocalStorage ?? json)
                else { return }
                self.finish(base, device: self.capturedDevice ?? base.deviceID, captcha: self.capturedCaptcha)
            }
        }

        private func finish(_ base: PikPakWebCredentials, device: String?, captcha: String?) {
            captured = true
            onCapture(PikPakWebCredentials(accessToken: base.accessToken,
                                           refreshToken: base.refreshToken,
                                           userID: base.userID,
                                           deviceID: device,
                                           expiresIn: base.expiresIn,
                                           captchaToken: captcha))
        }
    }

    /// Injected at document start: pushes localStorage snapshots (for tokens)
    /// and captures the captcha / device headers from the SPA's own API calls
    /// (fetch + XHR), so we reuse PikPak's valid captcha token instead of
    /// recomputing captcha_sign.
    static let captureJS = """
    (function () {
      function post(o) { try { window.webkit.messageHandlers.pikpak.postMessage(o); } catch (e) {} }
      function snapshot() { try { post({ type: 'ls', data: JSON.stringify(window.localStorage) }); } catch (e) {} }
      window.addEventListener('load', snapshot);
      setInterval(snapshot, 1500);

      function grab(headers) {
        if (!headers) return;
        try {
          var get = function (k) { return headers.get ? headers.get(k) : headers[k]; };
          var cap = get('x-captcha-token') || get('X-Captcha-Token');
          var dev = get('x-device-id') || get('X-Device-ID');
          if (cap || dev) post({ type: 'hdr', captcha: cap || '', device: dev || '' });
        } catch (e) {}
      }

      var origFetch = window.fetch;
      window.fetch = function (input, init) {
        try {
          if (init && init.headers) grab(init.headers);
          else if (input && input.headers) grab(input.headers);
        } catch (e) {}
        return origFetch.apply(this, arguments);
      };

      var origSet = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.setRequestHeader = function (k, v) {
        try {
          var key = (k || '').toLowerCase();
          if (key === 'x-captcha-token') post({ type: 'hdr', captcha: v, device: '' });
          if (key === 'x-device-id') post({ type: 'hdr', captcha: '', device: v });
        } catch (e) {}
        return origSet.apply(this, arguments);
      };
    })();
    """
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

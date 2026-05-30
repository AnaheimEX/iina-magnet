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

/// Sheet chrome (title + cancel) around the login web view.
struct PikPakLoginSheet: View {
    var onCancel: () -> Void
    var onCapture: (PikPakWebCredentials) -> Void

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

            PikPakLoginWebView(onCapture: onCapture)
        }
        .frame(width: 480, height: 640)
    }
}

/// WKWebView that loads PikPak's login page and reports captured tokens.
struct PikPakLoginWebView: NSViewRepresentable {
    var onCapture: (PikPakWebCredentials) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.captureJS,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        controller.add(context.coordinator, name: "pikpak")
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://mypikpak.com/")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let onCapture: (PikPakWebCredentials) -> Void
        private var captured = false

        // Latest pieces seen; assembled once tokens + captcha + device align.
        private var lastLocalStorage: String?
        private var capturedCaptcha: String?
        private var capturedDevice: String?
        private var fallbackScheduled = false

        init(onCapture: @escaping (PikPakWebCredentials) -> Void) {
            self.onCapture = onCapture
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
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
            webView.evaluateJavaScript("JSON.stringify(localStorage)") { [weak self] result, _ in
                guard let self else { return }
                if let json = result as? String { self.lastLocalStorage = json }
                self.attemptFinish()
            }
        }

        /// Finishes when we have tokens + a captured captcha token + a device id
        /// (a fully working session). Falls back to tokens-only after a short
        /// grace period if the SPA never makes an API call we can observe.
        private func attemptFinish() {
            guard !captured,
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, !self.captured,
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

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

        init(onCapture: @escaping (PikPakWebCredentials) -> Void) {
            self.onCapture = onCapture
        }

        // Periodic localStorage snapshot pushed from the injected script.
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let json = message.body as? String else { return }
            tryCapture(from: json)
        }

        // Also probe right after each navigation settles.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("JSON.stringify(localStorage)") { [weak self] result, _ in
                if let json = result as? String { self?.tryCapture(from: json) }
            }
        }

        private func tryCapture(from json: String) {
            guard !captured, let cred = PikPakWebCredentialParser.parse(localStorageJSON: json) else { return }
            captured = true
            onCapture(cred)
        }
    }

    /// Pushes a localStorage snapshot to native shortly after load and on a
    /// timer, so we notice the tokens as soon as login completes.
    static let captureJS = """
    (function () {
      function send() {
        try {
          window.webkit.messageHandlers.pikpak.postMessage(JSON.stringify(window.localStorage));
        } catch (e) {}
      }
      window.addEventListener('load', send);
      setInterval(send, 1500);
    })();
    """
}

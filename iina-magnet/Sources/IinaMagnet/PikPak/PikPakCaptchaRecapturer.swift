//
//  PikPakCaptchaRecapturer.swift
//  IinaMagnet
//
//  Silent captcha re-capture. When a drive call reports its captcha token
//  expired (error_code 9) and a self-signed replacement is rejected — which
//  happens whenever PikPak has rotated the captcha salts in PikPakConfig — we
//  briefly load the PikPak web client offscreen. Its JS computes a valid
//  captcha_sign with the *current* salts and attaches a fresh x-captcha-token
//  to its own API calls; we hook fetch/XHR to grab it (the same mechanism the
//  login web view uses). This avoids forcing the user to log in again.
//
//  Injectable behind a protocol so PikPakAuth's retry path is unit-testable
//  without a web view.

import Foundation

/// Re-captures a fresh, PikPak-minted captcha token (and the device id it is
/// bound to) by observing the web client. Throws on timeout / failure.
public protocol PikPakCaptchaRecapturing: Sendable {
    func recapture(homeURL: URL, userAgent: String,
                   timeoutSeconds: Double) async throws -> (token: String, deviceID: String?)
}

public enum PikPakCaptcha {
    /// The platform's default recapturer (WebKit-backed where available).
    public static var defaultRecapturer: PikPakCaptchaRecapturing {
        #if canImport(WebKit)
        WebViewCaptchaRecapturer()
        #else
        UnavailableCaptchaRecapturer()
        #endif
    }
}

/// Used when WebKit isn't available: there's no way to re-capture, so callers
/// fall back to prompting a fresh login.
struct UnavailableCaptchaRecapturer: PikPakCaptchaRecapturing {
    func recapture(homeURL: URL, userAgent: String,
                   timeoutSeconds: Double) async throws -> (token: String, deviceID: String?) {
        throw PikPakError.captchaRequired("PikPak 验证已过期，请重新登录 PikPak。")
    }
}

#if canImport(WebKit)
import WebKit

/// Default implementation: loads `homeURL` in an offscreen WKWebView (sharing
/// the app's persistent data store, so the already-logged-in SPA boots and
/// makes authenticated calls), and resolves with the first captcha token its
/// requests carry.
public struct WebViewCaptchaRecapturer: PikPakCaptchaRecapturing {
    public init() {}

    public func recapture(homeURL: URL, userAgent: String,
                          timeoutSeconds: Double) async throws -> (token: String, deviceID: String?) {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let driver = RecaptureDriver(homeURL: homeURL, userAgent: userAgent,
                                             timeoutSeconds: timeoutSeconds, continuation: continuation)
                driver.start()
            }
        }
    }
}

/// Owns the offscreen web view for one re-capture attempt and resolves the
/// continuation exactly once (on first captcha header, or on timeout).
@MainActor
private final class RecaptureDriver: NSObject, WKScriptMessageHandler {
    private let homeURL: URL
    private let timeoutSeconds: Double
    private var continuation: CheckedContinuation<(token: String, deviceID: String?), Error>?
    private var webView: WKWebView?
    private var device: String?

    init(homeURL: URL, userAgent: String, timeoutSeconds: Double,
         continuation: CheckedContinuation<(token: String, deviceID: String?), Error>) {
        self.homeURL = homeURL
        self.timeoutSeconds = timeoutSeconds
        self.continuation = continuation
        super.init()

        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(self, name: "pikpakCaptcha")
        controller.addUserScript(WKUserScript(source: Self.grabJS,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        config.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = userAgent
        self.webView = webView
    }

    func start() {
        webView?.load(URLRequest(url: homeURL))
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
            self?.fail(PikPakError.captchaRequired("PikPak 验证刷新超时，请重新登录 PikPak。"))
        }
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any] else { return }
        if let dev = (dict["device"] as? String)?.nonEmpty { device = dev }
        if let token = (dict["captcha"] as? String)?.nonEmpty {
            succeed(token: token, deviceID: device)
        }
    }

    private func succeed(token: String, deviceID: String?) {
        guard let continuation else { return }
        self.continuation = nil
        teardown()
        continuation.resume(returning: (token, deviceID))
    }

    private func fail(_ error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        teardown()
        continuation.resume(throwing: error)
    }

    private func teardown() {
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "pikpakCaptcha")
        webView = nil
    }

    /// Hooks fetch + XHR to forward any x-captcha-token / x-device-id header.
    static let grabJS = """
    (function () {
      function post(o) { try { window.webkit.messageHandlers.pikpakCaptcha.postMessage(o); } catch (e) {} }
      function grab(headers) {
        if (!headers) return;
        try {
          var get = function (k) { return headers.get ? headers.get(k) : headers[k]; };
          var cap = get('x-captcha-token') || get('X-Captcha-Token');
          var dev = get('x-device-id') || get('X-Device-ID');
          if (cap || dev) post({ captcha: cap || '', device: dev || '' });
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
          if (key === 'x-captcha-token') post({ captcha: v, device: '' });
          if (key === 'x-device-id') post({ captcha: '', device: v });
        } catch (e) {}
        return origSet.apply(this, arguments);
      };
    })();
    """
}
#endif

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

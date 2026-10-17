//
//  PikPakWebSession.swift
//  IinaMagnet
//
//  One owner for PikPak's *web* state, so a login survives quitting the app.
//
//  Why this file exists: PikPak has no public API. Everything we do is the web
//  client's own flow, and that flow keeps its state in two places —
//    1. `localStorage` on mypikpak.com (access_token / refresh_token), and
//    2. cookies on mypikpak.com (what lets the SPA boot already-logged-in and
//       mint a fresh captcha token).
//  The login sheet used to run in a `.nonPersistent()` data store, so (2) was
//  thrown away on every quit: the Keychain session alone cannot mint captcha
//  tokens, so the next launch had to prompt a full login again. Every PikPak web
//  view now shares WebKit's persistent store (`PikPakWebStore.dataStore`) and a
//  single capture script (`PikPakWebCapture.script`), and `PikPakWebProbe` can
//  read a session back out offscreen — silently restoring login on relaunch and
//  re-minting captcha tokens without user interaction.

import Foundation
import OSLog

// MARK: - Capture script (shared by every PikPak web view)

public enum PikPakWebCapture {
    /// Injected at document start into mypikpak.com. Pushes `localStorage`
    /// snapshots (where the SPA keeps its tokens) and mirrors the
    /// `x-captcha-token` / `x-device-id` headers off the SPA's own fetch/XHR
    /// traffic, so we reuse PikPak-minted captcha tokens instead of computing
    /// `captcha_sign` from salts that rotate.
    ///
    /// Message shape (both goals share it):
    ///   `{ type: 'ls',  data: <JSON.stringify(localStorage)> }`
    ///   `{ type: 'hdr', captcha: <string>, device: <string> }`
    public static func script(handler: String) -> String {
        """
        (function () {
          function post(o) { try { window.webkit.messageHandlers.\(handler).postMessage(o); } catch (e) {} }
          function snapshot() { try { post({ type: 'ls', data: JSON.stringify(window.localStorage) }); } catch (e) {} }
          snapshot();
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

    /// Parses one script message into the pieces we care about. Pure, so the
    /// message plumbing is unit-testable without a web view.
    public static func parseMessage(_ body: Any) -> Piece? {
        if let json = body as? String { return .localStorage(json) }   // legacy: bare snapshot
        guard let dict = body as? [String: Any] else { return nil }
        switch dict["type"] as? String {
        case "ls":
            guard let json = dict["data"] as? String, !json.isEmpty else { return nil }
            return .localStorage(json)
        case "hdr":
            let captcha = (dict["captcha"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let device = (dict["device"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard captcha != nil || device != nil else { return nil }
            return .headers(captcha: captcha, device: device)
        default:
            return nil
        }
    }

    public enum Piece: Equatable {
        case localStorage(String)
        case headers(captcha: String?, device: String?)
    }
}

#if canImport(WebKit)
import WebKit

// MARK: - Persistent website data store

@MainActor
public enum PikPakWebStore {
    private static let logger = Logger(subsystem: "iina-magnet", category: "pikpak-web")

    /// PikPak's own hosts. `mypikpak.com` serves the SPA; `mypikpak.net` is the
    /// API mirror this app talks to (see PikPakConfig).
    static let hosts = ["mypikpak.com", "mypikpak.net"]

    /// WebKit's persistent default store — the same one the Mikan browser uses.
    /// Persistence is the whole point: the cookies written here are what let a
    /// later launch boot the SPA already-logged-in (silent restore + captcha
    /// re-capture) instead of prompting a fresh login.
    public static var dataStore: WKWebsiteDataStore { .default() }

    /// Wipes cookies / localStorage / caches for PikPak's hosts only, leaving
    /// other sites (Mikan) untouched. Used on explicit sign-out and when a
    /// restored web session turns out to be dead, so the next login starts clean
    /// instead of re-adopting stale tokens in a loop.
    public static func clearSiteData() async {
        let store = dataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: types) { continuation.resume(returning: $0) }
        }
        let pikPak = records.filter { record in
            let name = record.displayName.lowercased()
            return hosts.contains { name == $0 || name.hasSuffix(".\($0)") }
        }
        guard !pikPak.isEmpty else { return }
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: types, for: pikPak) { continuation.resume() }
        }
        logger.info("cleared PikPak website data (\(pikPak.count, privacy: .public) record(s))")
    }
}

// MARK: - Offscreen probe

/// What an offscreen load of the PikPak web client should wait for.
enum PikPakWebProbeGoal {
    /// Resolve on the first PikPak-minted captcha token (used to re-mint a
    /// captcha token for drive calls).
    case captchaToken
    /// Resolve once `localStorage` yields an access/refresh token pair — i.e.
    /// the SPA booted already-logged-in from the persistent cookies (used to
    /// restore login silently on a new launch).
    case session
}

struct PikPakWebProbeResult: Sendable {
    var credentials: PikPakWebCredentials?
    var captchaToken: String?
    var deviceID: String?
}

/// Loads the PikPak web client in an offscreen `WKWebView` that shares the
/// persistent data store, and resolves with whatever the goal asks for. Resolves
/// its continuation exactly once (goal reached, timeout, or load failure).
@MainActor
final class PikPakWebProbe: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private static let logger = Logger(subsystem: "iina-magnet", category: "pikpak-web")
    private static let handlerName = "pikpakProbe"
    /// After tokens appear, wait briefly for a captcha token to accompany them
    /// (the SPA mints one on its first authenticated call) before resolving.
    private static let captchaGrace: TimeInterval = 2.5

    private let goal: PikPakWebProbeGoal
    private var continuation: CheckedContinuation<PikPakWebProbeResult, Error>?
    private var webView: WKWebView?
    private var credentials: PikPakWebCredentials?
    private var captcha: String?
    private var device: String?
    private var graceWork: DispatchWorkItem?
    private var timeoutWork: DispatchWorkItem?

    /// Runs one probe. Throws `PikPakError.captchaRequired` on timeout so
    /// callers can fall back to prompting an interactive login.
    static func run(goal: PikPakWebProbeGoal, url: URL, userAgent: String,
                    timeoutSeconds: Double) async throws -> PikPakWebProbeResult {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                PikPakWebProbe(goal: goal, continuation: continuation)
                    .start(url: url, userAgent: userAgent, timeoutSeconds: timeoutSeconds)
            }
        }
    }

    private init(goal: PikPakWebProbeGoal,
                 continuation: CheckedContinuation<PikPakWebProbeResult, Error>) {
        self.goal = goal
        self.continuation = continuation
        super.init()
    }

    private func start(url: URL, userAgent: String, timeoutSeconds: Double) {
        let config = WKWebViewConfiguration()
        // Shares the login sheet's persistent cookies — without them the SPA
        // boots signed-out and there is nothing to capture.
        config.websiteDataStore = PikPakWebStore.dataStore
        let controller = WKUserContentController()
        controller.add(self, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: PikPakWebCapture.script(handler: Self.handlerName),
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = userAgent          // the SPA requires its own UA
        webView.navigationDelegate = self
        self.webView = webView

        let work = DispatchWorkItem { [weak self] in
            self?.finishOnTimeout()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: work)
        webView.load(URLRequest(url: url))
    }

    // MARK: Capture

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard PikPakLoginNavigationPolicy.isCredentialOrigin(
            host: message.frameInfo.securityOrigin.host,
            isMainFrame: message.frameInfo.isMainFrame
        ) else { return }
        switch PikPakWebCapture.parseMessage(message.body) {
        case .localStorage(let json):
            if let parsed = PikPakWebCredentialParser.parse(localStorageJSON: json) {
                credentials = parsed
            }
        case .headers(let capturedCaptcha, let capturedDevice):
            if let capturedCaptcha { captcha = capturedCaptcha }
            if let capturedDevice { device = capturedDevice }
        case nil:
            break
        }
        evaluateGoal()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        fail(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail(PikPakError.transport("PikPak 页面进程意外退出"))
    }

    // MARK: Resolution

    private func evaluateGoal() {
        switch goal {
        case .captchaToken:
            if let captcha, !captcha.isEmpty { succeed() }
        case .session:
            guard credentials != nil else { return }
            // Tokens alone already restore the session; a captcha token makes
            // the first drive call work without a code-9 round trip, so allow a
            // short grace period for one to show up.
            if captcha != nil { succeed() } else { scheduleGrace() }
        }
    }

    private func scheduleGrace() {
        guard graceWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.succeed() }
        graceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captchaGrace, execute: work)
    }

    private func succeed() {
        guard let continuation else { return }
        self.continuation = nil
        let result = PikPakWebProbeResult(credentials: credentials,
                                          captchaToken: captcha,
                                          deviceID: device ?? credentials?.deviceID)
        teardown()
        continuation.resume(returning: result)
    }

    private func finishOnTimeout() {
        // A timeout that already collected tokens is still a success — only a
        // completely empty probe is a failure.
        if credentials != nil || (goal == .captchaToken && captcha?.isEmpty == false) {
            succeed()
            return
        }
        fail(PikPakError.captchaRequired("PikPak 登录状态已失效，请重新登录 PikPak。"))
    }

    private func fail(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        guard let continuation else { return }
        self.continuation = nil
        Self.logger.debug("PikPak web probe failed: \(error.localizedDescription, privacy: .public)")
        teardown()
        continuation.resume(throwing: error)
    }

    private func teardown() {
        graceWork?.cancel()
        graceWork = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        webView = nil
    }
}

// MARK: - Silent login restore

/// Restores a PikPak login from the persistent web session, with no UI: loads
/// the SPA offscreen and reads back the tokens it boots with. This is what makes
/// a relaunch skip the login sheet even when the stored Keychain session has
/// expired (PikPak rotates refresh tokens, and a captcha token cannot be minted
/// from tokens alone).
public enum PikPakSessionRestore {
    private static let logger = Logger(subsystem: "iina-magnet", category: "pikpak-web")

    /// Returns credentials captured from the logged-in web session, or nil when
    /// the web session is gone (a real login is required).
    @MainActor
    public static func attempt(timeoutSeconds: Double = 20) async -> PikPakWebCredentials? {
        let config = PikPakConfig.web
        do {
            let result = try await PikPakWebProbe.run(goal: .session,
                                                      url: PikPakSessionRestore.restoreURL(config),
                                                      userAgent: config.userAgent,
                                                      timeoutSeconds: timeoutSeconds)
            guard let base = result.credentials else { return nil }
            logger.info("restored PikPak session from persistent web state")
            return PikPakWebCredentials(accessToken: base.accessToken,
                                        refreshToken: base.refreshToken,
                                        userID: base.userID,
                                        deviceID: result.deviceID ?? base.deviceID,
                                        expiresIn: base.expiresIn,
                                        captchaToken: result.captchaToken)
        } catch {
            logger.debug("no PikPak web session to restore: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The drive route: loading it boots the authenticated SPA (which refreshes
    /// its own tokens and mints a captcha token) instead of the login form.
    static func restoreURL(_ config: PikPakConfig = .web) -> URL {
        config.webHomeURL.appendingPathComponent("drive/all")
    }
}
#endif

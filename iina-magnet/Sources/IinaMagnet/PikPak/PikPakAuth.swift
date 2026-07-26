//
//  PikPakAuth.swift
//  IinaMagnet
//
//  Orchestrates PikPak authentication for the signed-in user's own account:
//  captcha-token bootstrap → sign-in → session persistence → transparent
//  refresh. An actor so token state stays race-free across the concurrent
//  drive requests that will call `validAccessToken()`.
//
//  Flow replicated from PikPak's web client (see PikPakConfig): every auth call
//  carries `?client_id=` plus X-Device-ID / X-Captcha-Token headers. At sign-in
//  the captcha-init `meta` carries only the account identifier; PikPak issues a
//  captcha_token that the signin request then presents.

import Foundation
import OSLog

public actor PikPakAuth {
    private static let logger = Logger(subsystem: "iina-magnet", category: "pikpak-auth")

    /// UI surfaces observe this so a rejected/expired persisted session cannot
    /// leave the drive browser visible after the actor has cleared its state.
    public static let sessionDidChangeNotification =
        Notification.Name("iina-magnet.pikpak-session-did-change")

    /// App-wide session, shared by the login UI and (later) the file API.
    public static let shared = PikPakAuth()

    private let config: PikPakConfig
    private let http: PikPakHTTPClient
    private let store: PikPakTokenStore
    private let recapturer: PikPakCaptchaRecapturing
    private var session: PikPakSession?
    /// In-flight token refresh, so concurrent drive calls that all see an
    /// expired token coalesce onto ONE refresh. PikPak rotates the refresh
    /// token, so a second concurrent refresh would use a now-invalid token and
    /// kill the session.
    private var refreshTask: Task<String, Error>?
    /// Last captcha token minted for drive calls (PikPak issues these per
    /// action; re-minted lazily when a call reports it expired).
    private var driveCaptchaToken = ""

    public init(config: PikPakConfig = .web,
                http: PikPakHTTPClient = URLSessionPikPakClient(),
                store: PikPakTokenStore = KeychainPikPakTokenStore(),
                recapturer: PikPakCaptchaRecapturing = PikPakCaptcha.defaultRecapturer) {
        self.config = config
        self.http = http
        self.store = store
        self.recapturer = recapturer
        self.session = store.load()
    }

    public var isSignedIn: Bool { session != nil }
    public var userID: String? { session?.userID }
    public var currentDeviceID: String? { session?.deviceID }

    // MARK: - Public API

    /// Logs in with the user's own PikPak account and persists the session.
    public func signIn(username: String, password: String) async throws {
        // Cancel any in-flight refresh so a stale rotation cannot overwrite
        // this fresh session (symmetric with signOut).
        refreshTask?.cancel()
        refreshTask = nil
        guard !username.isEmpty, !password.isEmpty else { throw PikPakError.missingCredentials }
        let device = stableDeviceID()
        let captcha = try await fetchCaptchaToken(username: username, deviceID: device)
        let token = try await postSignIn(username: username, password: password,
                                         captcha: captcha, deviceID: device)
        let newSession = PikPakSession(
            accessToken: token.access_token,
            refreshToken: token.refresh_token,
            userID: token.sub ?? "",
            deviceID: device,
            expiresAt: Date().addingTimeInterval(TimeInterval(token.expires_in ?? 7200)))
        session = newSession
        store.save(newSession)
        notifySessionDidChange()
        Self.logger.info("signed in (sub=\(newSession.userID, privacy: .private(mask: .hash)))")
    }

    /// Adopts tokens captured from a web-view login (the primary login path —
    /// PikPak's page handles captcha / 2FA, we keep the resulting session).
    public func adopt(_ web: PikPakWebCredentials) {
        // Cancel any in-flight refresh so a stale rotation cannot overwrite
        // this fresh session (symmetric with signOut).
        refreshTask?.cancel()
        refreshTask = nil
        let device = web.deviceID ?? stableDeviceID()
        // Reuse the captcha token PikPak's own page already minted, so drive
        // calls don't need a self-computed (salt-dependent) captcha_sign.
        driveCaptchaToken = web.captchaToken ?? ""
        let newSession = PikPakSession(
            accessToken: web.accessToken,
            refreshToken: web.refreshToken,
            userID: web.userID,
            deviceID: device,
            expiresAt: Date().addingTimeInterval(TimeInterval(web.expiresIn ?? 7200)))
        session = newSession
        store.save(newSession)
        notifySessionDidChange()
        Self.logger.info("adopted web session (sub=\(newSession.userID, privacy: .private(mask: .hash)))")
    }

    /// A valid access token, refreshing transparently (and coalesced) if it's
    /// near expiry.
    public func validAccessToken() async throws -> String {
        guard let current = session else { throw PikPakError.notAuthenticated }
        guard current.isExpired else { return current.accessToken }
        return try await refreshAccessToken()
    }

    public func signOut() {
        // Cancel any in-flight refresh so it cannot revive the session we are
        // tearing down: performRefresh captures the old session and would
        // store.save() a fresh one after we cleared it.
        refreshTask?.cancel()
        refreshTask = nil
        session = nil
        driveCaptchaToken = ""
        store.clear()
        notifySessionDidChange()
    }

    // MARK: - For the drive API

    public var userAgent: String { config.userAgent }

    /// The current captcha token (captured at login), if any.
    public var currentCaptchaToken: String { driveCaptchaToken }

    /// Forces an access-token refresh (used when PikPak rejects a token the
    /// client still considered valid). Concurrent callers coalesce onto one
    /// in-flight refresh so the rotating refresh_token is never used twice.
    public func refreshAccessToken() async throws -> String {
        if let existing = refreshTask { return try await existing.value }
        let task = Task { try await self.performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> String {
        guard let current = session else { throw PikPakError.notAuthenticated }
        let token = try await postRefresh(refreshToken: current.refreshToken)
        // signOut/adopt/signIn may have cancelled this task or swapped the
        // session during the await. Bail before overwriting/persisting: Swift
        // cancellation is cooperative (cancel only sets a flag), so without
        // this guard a stale refresh revives a torn-down session or clobbers
        // a fresh login.
        try Task.checkCancellation()
        guard session?.refreshToken == current.refreshToken else {
            throw CancellationError()
        }
        var updated = current
        updated.accessToken = token.access_token
        updated.refreshToken = token.refresh_token
        if let sub = token.sub, !sub.isEmpty { updated.userID = sub }
        updated.expiresAt = Date().addingTimeInterval(TimeInterval(token.expires_in ?? 7200))
        session = updated
        store.save(updated)
        notifySessionDidChange()
        return updated.accessToken
    }

    /// A captcha token for a drive `action` (e.g. `GET:/drive/v1/files`), signed
    /// with captcha_sign over the configured salts. Cached; pass `refresh` to
    /// force a new one (after PikPak reports the token expired).
    public func captchaToken(forAction action: String, refresh: Bool = false) async throws -> String {
        if !refresh, !driveCaptchaToken.isEmpty { return driveCaptchaToken }
        guard let current = session else { throw PikPakError.notAuthenticated }

        let timestamp = PikPakCrypto.timestampMillis()
        let sign = PikPakCrypto.captchaSign(config: config, deviceID: current.deviceID,
                                            timestampMillis: timestamp)
        let meta = ["client_version": config.clientVersion,
                    "package_name": config.packageName,
                    "user_id": current.userID,
                    "timestamp": timestamp,
                    "captcha_sign": sign]
        let request = CaptchaInitRequest(action: action, captcha_token: driveCaptchaToken,
                                         client_id: config.clientID, device_id: current.deviceID,
                                         meta: meta, redirect_uri: config.redirectURI)
        let (data, status) = try await post(config.captchaInitURL, body: request,
                                            headers: headers(deviceID: current.deviceID, captcha: nil))
        if let error = decodeError(data, status: status) { throw error }
        let response = try decode(CaptchaInitResponse.self, from: data)
        guard let token = response.captcha_token, !token.isEmpty else {
            throw PikPakError.captchaRequired("无法获取验证令牌")
        }
        driveCaptchaToken = token
        return token
    }

    /// Silently re-captures a fresh captcha token from the PikPak web client
    /// (offscreen), used when a self-signed token is rejected because the salts
    /// rotated. Adopts the captured token (and keeps the device id it's bound to
    /// in sync, so the X-Device-ID header matches). Throws if capture fails, so
    /// the caller can fall back to prompting a fresh login.
    public func recaptureCaptchaToken(timeoutSeconds: Double = 15) async throws -> String {
        let result = try await recapturer.recapture(homeURL: config.webHomeURL,
                                                     userAgent: config.userAgent,
                                                     timeoutSeconds: timeoutSeconds)
        guard !result.token.isEmpty else {
            throw PikPakError.captchaRequired("PikPak 验证已过期，请重新登录 PikPak。")
        }
        driveCaptchaToken = result.token
        if let device = result.deviceID, !device.isEmpty,
           var current = session, current.deviceID != device {
            current.deviceID = device
            session = current
            store.save(current)
            notifySessionDidChange()
        }
        return result.token
    }

    // MARK: - Auth steps

    /// Bootstraps a captcha_token for the sign-in action. The meta carries only
    /// the account identifier (email / phone / username), matching the web
    /// client — captcha_sign isn't required for the signin action itself.
    private func fetchCaptchaToken(username: String, deviceID: String) async throws -> String {
        let request = CaptchaInitRequest(
            action: PikPakCrypto.action(method: "POST", url: config.signInURL),
            captcha_token: "",
            client_id: config.clientID,
            device_id: deviceID,
            meta: signInMeta(for: username),
            redirect_uri: config.redirectURI)

        let (data, status) = try await post(config.captchaInitURL, body: request,
                                            headers: headers(deviceID: deviceID, captcha: nil))
        if let error = decodeError(data, status: status) { throw error }

        let response = try decode(CaptchaInitResponse.self, from: data)
        if let url = response.url, !url.isEmpty {
            throw PikPakError.captchaRequired("需要在浏览器中完成人机验证后重试：\(url)")
        }
        guard let token = response.captcha_token, !token.isEmpty else {
            throw PikPakError.captchaRequired("未能获取验证令牌，请稍后重试")
        }
        return token
    }

    private func postSignIn(username: String, password: String,
                            captcha: String, deviceID: String) async throws -> TokenResponse {
        let request = SignInRequest(captcha_token: captcha,
                                    client_id: config.clientID,
                                    client_secret: config.clientSecret,
                                    username: username, password: password)
        let (data, status) = try await post(config.signInURL, body: request,
                                            headers: headers(deviceID: deviceID, captcha: captcha))
        if let error = decodeError(data, status: status) { throw error }
        return try decode(TokenResponse.self, from: data)
    }

    private func postRefresh(refreshToken: String) async throws -> TokenResponse {
        let request = RefreshTokenRequest(client_id: config.clientID,
                                          client_secret: config.clientSecret,
                                          grant_type: "refresh_token",
                                          refresh_token: refreshToken)
        let (data, status) = try await post(config.tokenURL, body: request,
                                            headers: ["User-Agent": config.userAgent])
        if let error = decodeError(data, status: status) {
            // Only a genuinely dead refresh token / auth denial wipes the
            // session. Transient API errors (e.g. 5xx with a body) must keep
            // it so a retry can still succeed instead of forcing a fresh login.
            let deadToken: Bool
            switch error {
            case .api(let code, let message):
                deadToken = code == 4126 || code == 4121
                    || message.lowercased().contains("invalid_grant")
            case .http(let status):
                deadToken = status == 401 || status == 403
            default:
                deadToken = false
            }
            if deadToken {
                session = nil
                store.clear()
                notifySessionDidChange()
                throw PikPakError.notAuthenticated
            }
            throw error
        }
        return try decode(TokenResponse.self, from: data)
    }

    // MARK: - Helpers

    private func signInMeta(for username: String) -> [String: String] {
        if username.contains("@") { return ["email": username] }
        if (11...18).contains(username.count),
           username.allSatisfy({ $0.isNumber || $0 == "+" }) { return ["phone_number": username] }
        return ["username": username]
    }

    private func notifySessionDidChange() {
        NotificationCenter.default.post(name: Self.sessionDidChangeNotification, object: nil)
    }

    /// The session's device id, else a freshly minted one. Web login supplies
    /// its own; the password fallback mints one per fresh login.
    private func stableDeviceID() -> String {
        session?.deviceID ?? PikPakCrypto.randomDeviceID()
    }

    private func headers(deviceID: String, captcha: String?) -> [String: String] {
        var h = ["User-Agent": config.userAgent, "X-Device-ID": deviceID]
        if let captcha, !captcha.isEmpty { h["X-Captcha-Token"] = captcha }
        return h
    }

    private func post<Body: Encodable>(_ url: URL, body: Body,
                                       headers: [String: String]) async throws -> (Data, Int) {
        let encoded = try JSONEncoder().encode(body)
        return try await http.postJSON(appendingClientID(to: url), body: encoded, headers: headers)
    }

    /// PikPak expects `?client_id=` on every auth request.
    private func appendingClientID(to url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "client_id", value: config.clientID)]
        return comps.url ?? url
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw PikPakError.decoding(String(data: data, encoding: .utf8) ?? "\(error)") }
    }

    /// Surfaces PikPak's error envelope. Returns nil for success bodies (which
    /// also match the all-optional error struct but carry no error fields).
    private func decodeError(_ data: Data, status: Int) -> PikPakError? {
        if let envelope = try? JSONDecoder().decode(PikPakErrorResponse.self, from: data) {
            let hasCode = (envelope.error_code ?? 0) != 0
            let hasError = (envelope.error?.isEmpty == false)
            if hasCode || (hasError && status >= 400) {
                let message = envelope.error_description?.nonEmpty
                    ?? envelope.error?.nonEmpty ?? "PikPak 返回未知错误"
                return .api(code: envelope.error_code ?? status, message: message)
            }
        }
        return status >= 400 ? .http(status: status) : nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

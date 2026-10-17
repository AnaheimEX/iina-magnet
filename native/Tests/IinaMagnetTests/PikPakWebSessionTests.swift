//
//  PikPakWebSessionTests.swift
//  IinaMagnetTests
//
//  Unit tests for the shared web-capture layer that backs the login-sheet /
//  offscreen-probe / recapturer unification. The WebKit-backed probe itself is
//  covered by an integration smoke (it needs a live web view); these tests
//  cover the pure pieces — the capture-script message parser and the
//  session-restore URL — so a regression in the bridge logic is caught without
//  spinning up WebKit.

import Foundation
import Testing
@testable import IinaMagnet

@Suite struct PikPakWebCaptureTests {

    // MARK: parseMessage

    @Test func parsesLegacyBareLocalStorageSnapshot() {
        let piece = PikPakWebCapture.parseMessage("{\"access_token\":\"a\"}")
        #expect(piece == .localStorage("{\"access_token\":\"a\"}"))
    }

    @Test func parsesLocalStorageMessage() {
        let body: [String: Any] = ["type": "ls", "data": "{\"access_token\":\"a\"}"]
        #expect(PikPakWebCapture.parseMessage(body) == .localStorage("{\"access_token\":\"a\"}"))
    }

    @Test func ignoresEmptyLocalStoragePayload() {
        let body: [String: Any] = ["type": "ls", "data": ""]
        #expect(PikPakWebCapture.parseMessage(body) == nil)
    }

    @Test func parsesCaptchaHeaderOnly() {
        let body: [String: Any] = ["type": "hdr", "captcha": "CAP", "device": ""]
        let piece = PikPakWebCapture.parseMessage(body)
        guard case .headers(let captcha, let device) = piece else {
            Issue.record("expected .headers"); return
        }
        #expect(captcha == "CAP")
        #expect(device == nil)
    }

    @Test func parsesDeviceHeaderOnly() {
        let body: [String: Any] = ["type": "hdr", "captcha": "", "device": "DEV"]
        let piece = PikPakWebCapture.parseMessage(body)
        guard case .headers(let captcha, let device) = piece else {
            Issue.record("expected .headers"); return
        }
        #expect(captcha == nil)
        #expect(device == "DEV")
    }

    @Test func ignoresHeaderMessageWithNoValues() {
        let body: [String: Any] = ["type": "hdr", "captcha": "", "device": ""]
        #expect(PikPakWebCapture.parseMessage(body) == nil)
    }

    @Test func ignoresUnknownMessageType() {
        let body: [String: Any] = ["type": "unknown", "data": "x"]
        #expect(PikPakWebCapture.parseMessage(body) == nil)
    }

    @Test func ignoresNonStringNonDictBody() {
        #expect(PikPakWebCapture.parseMessage(42) == nil)
        #expect(PikPakWebCapture.parseMessage(["a", "b"]) == nil)
    }

    // MARK: script

    @Test func scriptReferencesProvidedHandlerName() {
        let js = PikPakWebCapture.script(handler: "pikpakProbe")
        #expect(js.contains("window.webkit.messageHandlers.pikpakProbe"))
        #expect(!js.contains("pikpak\""))
    }

    @Test func scriptHooksFetchAndXHRForCaptchaAndDevice() {
        let js = PikPakWebCapture.script(handler: "pikpak")
        #expect(js.contains("x-captcha-token"))
        #expect(js.contains("x-device-id"))
        #expect(js.contains("XMLHttpRequest.prototype.setRequestHeader"))
        #expect(js.contains("window.fetch"))
        #expect(js.contains("JSON.stringify(window.localStorage)"))
    }
}

@Suite struct PikPakSessionRestoreURLTests {

    @Test func restoreURLPointsAtDriveRoute() throws {
        let url = PikPakSessionRestore.restoreURL()
        #expect(url.scheme == "https")
        #expect(url.host == "mypikpak.com")
        #expect(url.path == "/drive/all")
    }

    @Test func restoreURLRespectsConfigWebHome() {
        var config = PikPakConfig.web
        config.webHomeURL = URL(string: "https://mypikpak.net/")!
        let url = PikPakSessionRestore.restoreURL(config)
        #expect(url.host == "mypikpak.net")
        #expect(url.path == "/drive/all")
    }
}

@Suite struct PikPakSessionCaptchaPersistenceTests {

    @Test func adoptPersistsCapturedCaptchaToken() async throws {
        let store = InMemoryPikPakTokenStore()
        let auth = PikPakAuth(config: .web, http: StubPikPakClient([:]), store: store)
        await auth.adopt(PikPakWebCredentials(accessToken: "a", refreshToken: "r",
                                              userID: "u", deviceID: "d", expiresIn: 7200,
                                              captchaToken: "CAP"))
        let saved = try #require(store.load())
        #expect(saved.captchaToken == "CAP")
        #expect(saved.captchaCapturedAt != nil)
        #expect(await auth.currentCaptchaToken == "CAP")
    }

    @Test func captchaTokenMintedForDriveIsPersisted() async throws {
        let client = StubPikPakClient([
            "/v1/shield/captcha/init": (200, "{\"captcha_token\":\"ct-1\"}"),
        ])
        let store = InMemoryPikPakTokenStore(
            PikPakSession(accessToken: "a", refreshToken: "r", userID: "u",
                          deviceID: "dev", expiresAt: Date().addingTimeInterval(3600)))
        let auth = PikPakAuth(config: .web, http: client, store: store)
        let token = try await auth.captchaToken(forAction: "GET:/drive/v1/files")
        #expect(token == "ct-1")
        let saved = try #require(store.load())
        #expect(saved.captchaToken == "ct-1")
        #expect(saved.captchaCapturedAt != nil)
    }

    @Test func recaptureAdoptsTokenAndPersistsIt() async throws {
        let store = InMemoryPikPakTokenStore(
            PikPakSession(accessToken: "a", refreshToken: "r", userID: "u",
                          deviceID: "old", expiresAt: Date().addingTimeInterval(3600)))
        let auth = PikPakAuth(config: .web, http: StubPikPakClient([:]), store: store,
                              recapturer: StubRecapturer(token: "CAP-NEW", device: "newdev"))
        _ = try await auth.recaptureCaptchaToken()
        let saved = try #require(store.load())
        #expect(saved.captchaToken == "CAP-NEW")
        #expect(saved.deviceID == "newdev")
    }

    @Test func initHydratesCaptchaTokenFromStore() async {
        let store = InMemoryPikPakTokenStore(
            PikPakSession(accessToken: "a", refreshToken: "r", userID: "u",
                          deviceID: "d", expiresAt: Date().addingTimeInterval(3600),
                          captchaToken: "HYDRATED"))
        let auth = PikPakAuth(config: .web, http: StubPikPakClient([:]), store: store)
        #expect(await auth.currentCaptchaToken == "HYDRATED")
    }

    @Test func signOutClearsPersistedCaptchaToken() async throws {
        let store = InMemoryPikPakTokenStore()
        let auth = PikPakAuth(config: .web, http: StubPikPakClient([:]), store: store)
        await auth.adopt(PikPakWebCredentials(accessToken: "a", refreshToken: "r",
                                              userID: "u", deviceID: "d", expiresIn: 7200,
                                              captchaToken: "CAP"))
        await auth.signOut()
        #expect(store.load() == nil)
        #expect(await auth.currentCaptchaToken == "")
    }
}

@Suite struct PikPakDriveSessionVerificationTests {

    @Test func verifySessionValidForAcceptedToken() async throws {
        let stub = QueueStub(["/drive/v1/about": [(200, #"{\"quota\":{\"limit\":\"0\"}}"#)]])
        let drive = PikPakDrive(auth: signedInAuth(stub), http: stub, config: .web)
        #expect(await drive.verifySession() == .valid)
        #expect(stub.gets.count == 1)
        #expect(stub.gets.first?.url.path.contains("/drive/v1/about") == true)
    }

    @Test func verifySessionDeadForRejectedToken() async {
        // 401/code-16 first triggers the refresh retry, so the dead verdict
        // only lands once the refresh itself is rejected with a dead token.
        let stub = QueueStub([
            "/drive/v1/about": [(401, #"{"error":"unauthorized","error_code":16}"#)],
            "/v1/auth/token": [(400, #"{"error":"invalid_grant","error_code":4126}"#)],
        ])
        let drive = PikPakDrive(auth: signedInAuth(stub), http: stub, config: .web)
        #expect(await drive.verifySession() == .dead)
    }

    @Test func verifySessionUnavailableOnTransportError() async {
        struct CrashingClient: PikPakHTTPClient {
            func postJSON(_ url: URL, body: Data, headers: [String: String]) async throws -> (Data, Int) {
                throw PikPakError.transport("boom")
            }
            func getJSON(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
                throw PikPakError.transport("boom")
            }
            func deleteJSON(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
                throw PikPakError.transport("boom")
            }
        }
        let drive = PikPakDrive(auth: signedInAuth(QueueStub([:])), http: CrashingClient(), config: .web)
        #expect(await drive.verifySession() == .unavailable)
    }

    @Test func classifiesDeadAndTransientFailures() {
        #expect(PikPakDrive.classifyVerificationFailure(PikPakError.api(code: 4126, message: "x")) == .dead)
        #expect(PikPakDrive.classifyVerificationFailure(PikPakError.api(code: 4121, message: "x")) == .dead)
        #expect(PikPakDrive.classifyVerificationFailure(PikPakError.api(code: 16, message: "x")) == .dead)
        #expect(PikPakDrive.classifyVerificationFailure(PikPakError.api(code: 400, message: "invalid_grant")) == .dead)
        #expect(PikPakDrive.classifyVerificationFailure(PikPakError.http(status: 401)) == .dead)
        #expect(PikPakDrive.classifyVerificationFailure(PikPakError.http(status: 403)) == .dead)
        #expect(PikPakDrive.classifyVerificationFailure(PikPakError.notAuthenticated) == .dead)
        #expect(PikPakDrive.classifyVerificationFailure(PikPakError.transport("boom")) == .unavailable)
        #expect(PikPakDrive.classifyVerificationFailure(PikPakError.decoding("bad")) == .unavailable)
        #expect(PikPakDrive.classifyVerificationFailure(PikPakError.http(status: 500)) == .unavailable)
        #expect(PikPakDrive.classifyVerificationFailure(PikPakError.api(code: 9, message: "captcha")) == .unavailable)
    }
}

@Suite struct PikPakRestoreLatchTests {

    @Test func restoreShortCircuitsWhenSignedIn() async {
        let auth = PikPakAuth(config: .web, http: StubPikPakClient([:]),
                              store: InMemoryPikPakTokenStore(PikPakSession(
                                  accessToken: "a", refreshToken: "r",
                                  userID: "u", deviceID: "d",
                                  expiresAt: Date(timeIntervalSinceNow: 3600))))
        #expect(await auth.restoreFromWebSessionIfNeeded())
    }
}

// Local helpers — the test file is self-contained for the new suite.
private struct StubRecapturer: PikPakCaptchaRecapturing {
    let token: String
    let device: String?
    func recapture(homeURL: URL, userAgent: String,
                   timeoutSeconds: Double) async throws -> (token: String, deviceID: String?) {
        (token, device)
    }
}

private struct StubPikPakClient: PikPakHTTPClient, @unchecked Sendable {
    private let routes: [String: (Int, String)]
    init(_ routes: [String: (Int, String)]) { self.routes = routes }
    func postJSON(_ url: URL, body: Data, headers: [String: String]) async throws -> (Data, Int) {
        for (path, route) in routes where url.path.contains(path) {
            return (Data(route.1.utf8), route.0)
        }
        return (Data("{}".utf8), 404)
    }
    func getJSON(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        try await postJSON(url, body: Data(), headers: headers)
    }
    func deleteJSON(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        try await postJSON(url, body: Data(), headers: headers)
    }
}

private func signedInAuth(_ stub: QueueStub) -> PikPakAuth {
    PikPakAuth(config: .web, http: stub, store: InMemoryPikPakTokenStore(
        PikPakSession(accessToken: "acc", refreshToken: "ref", userID: "u-1",
                      deviceID: "0123456789abcdef0123456789abcdef",
                      expiresAt: Date().addingTimeInterval(7200))))
}

// Reuses the QueueStub defined in PikPakDriveTests.swift via @testable import.
private final class QueueStub: PikPakHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: [(status: Int, json: String)]]
    private(set) var gets: [(url: URL, headers: [String: String])] = []
    init(_ queues: [String: [(status: Int, json: String)]]) { self.queues = queues }
    private func pop(_ url: URL) -> (Data, Int) {
        lock.withLock {
            for path in queues.keys.sorted(by: { $0.count > $1.count }) where url.path.contains(path) {
                var arr = queues[path]!
                let r = arr.count > 1 ? arr.removeFirst() : arr[0]
                queues[path] = arr
                return (Data(r.json.utf8), r.status)
            }
            return (Data("{}".utf8), 404)
        }
    }
    func getJSON(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        lock.withLock { gets.append((url, headers)) }
        return pop(url)
    }
    func postJSON(_ url: URL, body: Data, headers: [String: String]) async throws -> (Data, Int) {
        pop(url)
    }
    func deleteJSON(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        pop(url)
    }
}

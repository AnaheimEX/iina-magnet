//
//  PikPakAuthTests.swift
//  IinaMagnetTests
//
//  Two layers: the deterministic captcha-sign primitives (the part that must
//  match PikPak's web client byte-for-byte), and the sign-in / refresh flow
//  driven through a recording stub HTTP client (no network).

import Testing
import Foundation
@testable import IinaMagnet

// MARK: - Signing primitives

@Suite struct PikPakCryptoTests {

    @Test func md5MatchesKnownVectors() {
        #expect(PikPakCrypto.md5Hex("") == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(PikPakCrypto.md5Hex("abc") == "900150983cd24fb0d6963f7d28e17f72")
        #expect(PikPakCrypto.md5Hex("The quick brown fox jumps over the lazy dog")
                == "9e107d9d372bb6826bd81d3542a419d6")
    }

    @Test func captchaSignFormatIsVersionedHex() {
        let sign = PikPakCrypto.captchaSign(config: .web, deviceID: "dev123", timestampMillis: "1700000000000")
        #expect(sign.hasPrefix("1."))
        let hex = String(sign.dropFirst(2))
        #expect(hex.count == 32)
        #expect(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test func captchaSignIsDeterministicAndInputSensitive() {
        let a = PikPakCrypto.captchaSign(config: .web, deviceID: "dev", timestampMillis: "1")
        let again = PikPakCrypto.captchaSign(config: .web, deviceID: "dev", timestampMillis: "1")
        #expect(a == again)                                   // pure
        let diffTime = PikPakCrypto.captchaSign(config: .web, deviceID: "dev", timestampMillis: "2")
        let diffDev  = PikPakCrypto.captchaSign(config: .web, deviceID: "dev2", timestampMillis: "1")
        #expect(a != diffTime)
        #expect(a != diffDev)
    }

    @Test func captchaSignDependsOnSaltOrder() {
        var reordered = PikPakConfig.web
        reordered.captchaSalts.reverse()
        let normal = PikPakCrypto.captchaSign(config: .web, deviceID: "d", timestampMillis: "1")
        let swapped = PikPakCrypto.captchaSign(config: reordered, deviceID: "d", timestampMillis: "1")
        #expect(normal != swapped)
    }

    @Test func actionIsMethodColonPath() {
        let url = URL(string: "https://user.mypikpak.net/v1/auth/signin")!
        #expect(PikPakCrypto.action(method: "POST", url: url) == "POST:/v1/auth/signin")
    }

    @Test func randomDeviceIDIs32HexAndUnique() {
        let a = PikPakCrypto.randomDeviceID()
        #expect(a.count == 32)
        #expect(a.allSatisfy { $0.isHexDigit })
        #expect(a != PikPakCrypto.randomDeviceID())
    }
}

// MARK: - Stub transport

private struct StubRequest: Sendable {
    let url: URL
    let body: Data
    let headers: [String: String]
}

/// Routes by URL path to a canned (json, status); records every request.
private final class StubPikPakClient: PikPakHTTPClient, @unchecked Sendable {
    typealias Route = (status: Int, json: String)
    private let lock = NSLock()
    private var routes: [String: Route]
    private(set) var requests: [StubRequest] = []

    init(_ routes: [String: Route]) { self.routes = routes }

    func request(forPathContaining s: String) -> StubRequest? {
        lock.withLock { requests.first { $0.url.path.contains(s) } }
    }

    func postJSON(_ url: URL, body: Data, headers: [String: String]) async throws -> (Data, Int) {
        lock.withLock { requests.append(StubRequest(url: url, body: body, headers: headers)) }
        for (path, route) in routes where url.path.contains(path) {
            return (Data(route.json.utf8), route.status)
        }
        return (Data("{}".utf8), 404)
    }

    func getJSON(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        try await postJSON(url, body: Data(), headers: headers)
    }
}

private let okCaptcha: (Int, String) = (200, #"{"captcha_token":"ct-xyz","expires_in":300}"#)
private func tokenJSON(access: String = "acc-1", refresh: String = "ref-1",
                       expires: Int = 7200, sub: String = "u-42") -> String {
    #"{"access_token":"\#(access)","refresh_token":"\#(refresh)","expires_in":\#(expires),"token_type":"Bearer","sub":"\#(sub)"}"#
}

// MARK: - Flow

@Suite struct PikPakAuthFlowTests {

    @Test func signInPersistsSessionAndForwardsCaptcha() async throws {
        let client = StubPikPakClient([
            "/v1/shield/captcha/init": okCaptcha,
            "/v1/auth/signin": (200, tokenJSON()),
        ])
        let store = InMemoryPikPakTokenStore()
        let auth = PikPakAuth(config: .web, http: client, store: store)

        try await auth.signIn(username: "me@example.com", password: "pw")

        #expect(await auth.isSignedIn)
        #expect(await auth.userID == "u-42")
        #expect(try await auth.validAccessToken() == "acc-1")
        // Session was written to the store.
        #expect(store.load()?.refreshToken == "ref-1")

        // The signin request carried the captcha token from init (body + header).
        let signin = try #require(client.request(forPathContaining: "/v1/auth/signin"))
        #expect(signin.headers["X-Captcha-Token"] == "ct-xyz")
        let bodyText = String(data: signin.body, encoding: .utf8) ?? ""
        #expect(bodyText.contains("ct-xyz"))
        // client_id is on the query string of every call.
        #expect(signin.url.query?.contains("client_id=YUMx5nI8ZU8Ap8pm") == true)
        // Device id header present and stable across the two calls.
        let initReq = try #require(client.request(forPathContaining: "captcha/init"))
        #expect(initReq.headers["X-Device-ID"] == signin.headers["X-Device-ID"])
        #expect(initReq.headers["X-Device-ID"]?.isEmpty == false)
    }

    @Test func emailVsUsernameMetaRouting() async throws {
        let client = StubPikPakClient([
            "/v1/shield/captcha/init": okCaptcha,
            "/v1/auth/signin": (200, tokenJSON()),
        ])
        let auth = PikPakAuth(config: .web, http: client, store: InMemoryPikPakTokenStore())
        try await auth.signIn(username: "plainuser", password: "pw")
        let initReq = try #require(client.request(forPathContaining: "captcha/init"))
        let body = String(data: initReq.body, encoding: .utf8) ?? ""
        #expect(body.contains("\"username\""))
        #expect(!body.contains("\"email\""))
    }

    @Test func emptyCredentialsRejectedBeforeNetwork() async {
        let client = StubPikPakClient([:])
        let auth = PikPakAuth(config: .web, http: client, store: InMemoryPikPakTokenStore())
        await #expect(throws: PikPakError.missingCredentials) {
            try await auth.signIn(username: "", password: "")
        }
        #expect(client.requests.isEmpty)
    }

    @Test func humanVerificationSurfacesCaptchaRequired() async {
        let client = StubPikPakClient([
            "/v1/shield/captcha/init": (200, #"{"url":"https://user.mypikpak.com/verify?x=1"}"#),
        ])
        let auth = PikPakAuth(config: .web, http: client, store: InMemoryPikPakTokenStore())
        do {
            try await auth.signIn(username: "me@example.com", password: "pw")
            Issue.record("expected captchaRequired to be thrown")
        } catch PikPakError.captchaRequired { /* expected */ }
        catch { Issue.record("wrong error: \(error)") }
    }

    @Test func apiErrorOnSignInIsSurfaced() async {
        let client = StubPikPakClient([
            "/v1/shield/captcha/init": okCaptcha,
            "/v1/auth/signin": (400, #"{"error":"invalid_argument","error_code":16,"error_description":"密码错误"}"#),
        ])
        let auth = PikPakAuth(config: .web, http: client, store: InMemoryPikPakTokenStore())
        do {
            try await auth.signIn(username: "me@example.com", password: "bad")
            Issue.record("expected api error to be thrown")
        } catch let PikPakError.api(code, message) {
            #expect(code == 16)
            #expect(message == "密码错误")
        } catch { Issue.record("wrong error: \(error)") }
    }

    @Test func expiredSessionTriggersRefresh() async throws {
        let client = StubPikPakClient([
            "/v1/auth/token": (200, tokenJSON(access: "acc-2", refresh: "ref-2")),
        ])
        let store = InMemoryPikPakTokenStore(
            PikPakSession(accessToken: "old", refreshToken: "ref-1", userID: "u-42",
                          deviceID: "dev", expiresAt: Date().addingTimeInterval(-10)))
        let auth = PikPakAuth(config: .web, http: client, store: store)

        let token = try await auth.validAccessToken()
        #expect(token == "acc-2")
        #expect(store.load()?.refreshToken == "ref-2")    // rotated refresh token persisted
        let refresh = try #require(client.request(forPathContaining: "/v1/auth/token"))
        #expect(String(data: refresh.body, encoding: .utf8)?.contains("refresh_token") == true)
    }

    @Test func deadRefreshTokenClearsSession() async {
        let client = StubPikPakClient([
            "/v1/auth/token": (400, #"{"error":"invalid_grant","error_code":4126,"error_description":"expired"}"#),
        ])
        let store = InMemoryPikPakTokenStore(
            PikPakSession(accessToken: "old", refreshToken: "dead", userID: "u",
                          deviceID: "dev", expiresAt: Date().addingTimeInterval(-10)))
        let auth = PikPakAuth(config: .web, http: client, store: store)

        await #expect(throws: PikPakError.notAuthenticated) {
            _ = try await auth.validAccessToken()
        }
        #expect(await auth.isSignedIn == false)
        #expect(store.load() == nil)
    }

    @Test func validAccessTokenRequiresSignIn() async {
        let auth = PikPakAuth(config: .web, http: StubPikPakClient([:]),
                              store: InMemoryPikPakTokenStore())
        await #expect(throws: PikPakError.notAuthenticated) {
            _ = try await auth.validAccessToken()
        }
    }

    @Test func signOutClearsStore() async throws {
        let client = StubPikPakClient([
            "/v1/shield/captcha/init": okCaptcha,
            "/v1/auth/signin": (200, tokenJSON()),
        ])
        let store = InMemoryPikPakTokenStore()
        let auth = PikPakAuth(config: .web, http: client, store: store)
        try await auth.signIn(username: "me@example.com", password: "pw")
        await auth.signOut()
        #expect(await auth.isSignedIn == false)
        #expect(store.load() == nil)
    }
}

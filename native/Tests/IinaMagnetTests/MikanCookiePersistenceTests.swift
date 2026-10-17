//
//  MikanCookiePersistenceTests.swift
//  IinaMagnetTests
//
//  Regression coverage for restoring Mikan's session cookies before the first
//  navigation of a new app launch.

import Foundation
import Testing
import WebKit
@testable import IinaMagnet

@Suite struct MikanCookiePersistenceTests {

    private let authCookieName = ".AspNetCore.Identity.Application"

    @Test func sessionCookieRoundTripPreservesAuthenticationFlags() throws {
        let cookie = try #require(HTTPCookie(properties: [
            .name: authCookieName,
            .value: "secret",
            .domain: ".mikanani.me",
            .path: "/",
            .secure: "TRUE",
            .discard: "TRUE",
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
            .sameSitePolicy: "lax",
        ]))

        let data = try MikanCookieArchive(cookies: [cookie]).encoded()
        let restored = try #require(try MikanCookieArchive.decode(data).cookies().first)

        #expect(restored.name == cookie.name)
        #expect(restored.value == cookie.value)
        #expect(restored.domain == cookie.domain)
        #expect(restored.path == cookie.path)
        #expect(restored.isSessionOnly)
        #expect(restored.isSecure)
        #expect(restored.isHTTPOnly)
        #expect(restored.sameSitePolicy?.rawValue == "lax")
    }

    @Test func archiveKeepsOnlyLiveMikanAuthenticationCookies() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let valid = try cookie(name: authCookieName, domain: "account.mikanani.me",
                               expires: now.addingTimeInterval(3_600))
        let legacyDomain = try cookie(name: authCookieName, domain: ".mikan.me", expires: nil)
        let expired = try cookie(name: authCookieName, domain: "mikanani.me",
                                 expires: now.addingTimeInterval(-1))
        let unrelated = try cookie(name: authCookieName, domain: "example.com", expires: nil)
        let antiforgery = try cookie(name: ".AspNetCore.Antiforgery.token",
                                     domain: ".mikanani.me", expires: nil)

        let archive = MikanCookieArchive(
            cookies: [valid, legacyDomain, expired, unrelated, antiforgery], now: now
        )
        let restored = archive.cookies(now: now)

        #expect(Set(restored.map(\.domain)) == ["account.mikanani.me", ".mikan.me"])
        #expect(restored.allSatisfy { $0.name == authCookieName })
    }

    @Test func sessionCookieRecoveryHasABoundedLifetime() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let session = try cookie(name: authCookieName, domain: ".mikanani.me")
        let archive = MikanCookieArchive(cookies: [session], now: capturedAt)

        #expect(archive.cookies(now: capturedAt.addingTimeInterval(29 * 24 * 60 * 60)).count == 1)
        #expect(archive.cookies(now: capturedAt.addingTimeInterval(31 * 24 * 60 * 60)).isEmpty)
    }

    @Test func restoreCandidatesNeverOverwriteNewerWebKitCookies() throws {
        let archivedAuth = try cookie(name: authCookieName, value: "stale", domain: ".mikanani.me")
        let archivedAntiforgery = try cookie(name: ".AspNetCore.Antiforgery.old",
                                             value: "do-not-restore", domain: ".mikanani.me")
        let currentAuth = try cookie(name: authCookieName, value: "fresh", domain: ".mikanani.me")

        let candidates = MikanCookieArchive.restoreCandidates(
            archived: [archivedAuth, archivedAntiforgery],
            existing: [currentAuth]
        )

        #expect(candidates.isEmpty)
    }

@Test @MainActor func webKitRestoreCompletesBeforeReturningAndKeepsCurrentValue() async throws {
    let archivedAuth = try cookie(name: authCookieName, value: "stale", domain: ".mikanani.me")
    let currentAuth = try cookie(
        name: authCookieName,
        value: "fresh",
        domain: ".mikanani.me",
        expires: Date().addingTimeInterval(3600)
    )
        let store = InMemoryMikanCookieArchiveStore(
            try MikanCookieArchive(cookies: [archivedAuth]).encoded()
        )
        let persistence = MikanCookiePersistence(archiveStore: store)
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let cookieStore = dataStore.httpCookieStore
        await set(currentAuth, in: cookieStore)

        let restoredCount = await persistence.restoreMissingCookies(into: cookieStore)

        let cookies = await allCookies(in: cookieStore)
        #expect(restoredCount == 0)
    #expect(cookies.first { $0.name == authCookieName }?.value == "fresh")
}

@Test @MainActor func webKitRestoresMissingAuthenticationCookie() async throws {
        let archivedAuth = try cookie(name: authCookieName, value: "recover-me",
                                      domain: ".mikanani.me")
        let store = InMemoryMikanCookieArchiveStore(
            try MikanCookieArchive(cookies: [archivedAuth]).encoded()
        )
        let persistence = MikanCookiePersistence(archiveStore: store)
        // Retain the ephemeral data store for the whole async operation. Holding
        // only its cookie-store facade lets WebKit tear down the backing process
        // nondeterministically and made this integration test flaky.
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let cookieStore = dataStore.httpCookieStore

        let restoredCount = await persistence.restoreMissingCookies(into: cookieStore)

        let cookies = await allCookies(in: cookieStore)
        #expect(restoredCount == 1)
        #expect(cookies.first { $0.name == authCookieName }?.value == "recover-me")
    }

    @Test @MainActor func snapshotTracksRotationAndDoesNotReintroduceAuthAfterLogout() async throws {
        let store = InMemoryMikanCookieArchiveStore()
        let persistence = MikanCookiePersistence(archiveStore: store)
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let cookieStore = dataStore.httpCookieStore
        let rotated = try cookie(name: authCookieName, value: "rotated", domain: ".mikanani.me")
        let preference = try cookie(name: "theme", value: "dark", domain: ".mikanani.me")
        await set(rotated, in: cookieStore)
        await set(preference, in: cookieStore)

        await persistence.snapshot(from: cookieStore)

        let data = try #require(try store.load())
        let saved = try MikanCookieArchive.decode(data).cookies()
        #expect(saved.first { $0.name == authCookieName }?.value == "rotated")
        #expect(!saved.contains { $0.name == "theme" })

        await delete(rotated, from: cookieStore)
        await persistence.snapshot(from: cookieStore)
        #expect(try store.load() == nil)

        await delete(preference, from: cookieStore)
        await persistence.snapshot(from: cookieStore)
        #expect(try store.load() == nil)
    }

    @Test @MainActor func resetClearsMikanCookiesButLeavesOtherSitesAlone() async throws {
        let store = InMemoryMikanCookieArchiveStore()
        let persistence = MikanCookiePersistence(archiveStore: store)
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let cookieStore = dataStore.httpCookieStore
        let auth = try cookie(name: authCookieName, domain: ".mikanani.me")
        let unrelated = try cookie(name: "other", domain: "example.com")
        await set(auth, in: cookieStore)
        await set(unrelated, in: cookieStore)
        await persistence.snapshot(from: cookieStore)

        await persistence.clearAllCookies(from: cookieStore)

        let remaining = await allCookies(in: cookieStore)
        #expect(!remaining.contains { $0.name == authCookieName })
        #expect(remaining.contains { $0.name == "other" })
        #expect(try store.load() == nil)
    }

    @Test @MainActor func slowArchiveLoadRechecksWebKitAndKeepsNewerLoginCookie() async throws {
        let archived = try cookie(name: authCookieName, value: "stale", domain: ".mikanani.me")
        let fresh = try cookie(name: authCookieName, value: "fresh", domain: ".mikanani.me")
        let store = BlockingMikanCookieArchiveStore(
            try MikanCookieArchive(cookies: [archived]).encoded()
        )
        let persistence = MikanCookiePersistence(archiveStore: store)
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let cookieStore = dataStore.httpCookieStore

        let restore = Task { await persistence.restoreMissingCookies(into: cookieStore) }
        await store.waitUntilLoadStarts()
        await set(fresh, in: cookieStore)
        store.resumeLoad()

        #expect(await restore.value == 0)
        let cookies = await allCookies(in: cookieStore)
        #expect(cookies.first { $0.name == authCookieName }?.value == "fresh")
    }

    @Test @MainActor func cancelledSlowArchiveLoadPerformsNoLateCookieWrite() async throws {
        let archived = try cookie(name: authCookieName, value: "stale", domain: ".mikanani.me")
        let store = BlockingMikanCookieArchiveStore(
            try MikanCookieArchive(cookies: [archived]).encoded()
        )
        let persistence = MikanCookiePersistence(archiveStore: store)
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let cookieStore = dataStore.httpCookieStore

        let restore = Task { await persistence.restoreMissingCookies(into: cookieStore) }
        await store.waitUntilLoadStarts()
        restore.cancel()
        store.resumeLoad()

        #expect(await restore.value == 0)
        #expect(await allCookies(in: cookieStore).isEmpty)
    }

    @Test @MainActor func loadErrorDoesNotDeleteArchive() async throws {
        let store = FailingLoadMikanCookieArchiveStore()
        let persistence = MikanCookiePersistence(archiveStore: store)
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let cookieStore = dataStore.httpCookieStore

        let restoredCount = await persistence.restoreMissingCookies(into: cookieStore)

        #expect(restoredCount == 0)
        #expect(await allCookies(in: cookieStore).isEmpty)
        #expect(store.cleared == false)
        #expect(store.loadErrorTriggered == true)
    }

    private func cookie(name: String, value: String = "value", domain: String,
                        expires: Date? = nil) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
            .secure: "TRUE",
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        ]
        if let expires {
            properties[.expires] = expires
        } else {
            properties[.discard] = "TRUE"
        }
        return try #require(HTTPCookie(properties: properties))
    }

    @MainActor
    private func allCookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    @MainActor
    private func set(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) { continuation.resume() }
        }
    }

    @MainActor
    private func delete(_ cookie: HTTPCookie, from store: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            store.delete(cookie) { continuation.resume() }
        }
    }
}

private final class InMemoryMikanCookieArchiveStore: MikanCookieArchiveStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    init(_ data: Data? = nil) { self.data = data }

    func load() throws -> Data? { lock.withLock { data } }
    func save(_ data: Data) throws { lock.withLock { self.data = data } }
    func clear() throws { lock.withLock { data = nil } }
}

private final class BlockingMikanCookieArchiveStore: MikanCookieArchiveStore, @unchecked Sendable {
    private let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data: Data?
    private var loadStarted = false

    init(_ data: Data?) { self.data = data }

    func load() throws -> Data? {
        lock.withLock { loadStarted = true }
        resume.wait()
        return lock.withLock { data }
    }

    func save(_ data: Data) throws { lock.withLock { self.data = data } }
    func clear() throws { lock.withLock { data = nil } }

    func waitUntilLoadStarts() async {
        while !lock.withLock({ loadStarted }) {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func resumeLoad() { resume.signal() }
}

private final class FailingLoadMikanCookieArchiveStore: MikanCookieArchiveStore, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var loadErrorTriggered = false
    private(set) var cleared = false

    init() { }

    func load() throws -> Data? {
        lock.withLock { loadErrorTriggered = true }
        throw URLError(.cannotLoadFromNetwork)
    }

    func save(_ data: Data) throws { }
    func clear() throws { lock.withLock { cleared = true } }
}

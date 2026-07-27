//
//  MikanCookiePersistence.swift
//  IinaMagnet
//
//  WebKit's persistent data store remains the primary cookie store. This file
//  adds a Keychain-backed recovery copy for session cookies and for launches
//  where WebKit has not hydrated its on-disk cookie store before the first
//  request.

import Foundation
import LocalAuthentication
import OSLog
import Security
import WebKit

// MARK: - Serializable cookie archive

struct MikanCookieArchive: Codable, Sendable {
    private static let currentVersion = 1
    private static let supportedDomains = ["mikanani.me", "mikan.me"]
    /// Mikan uses ASP.NET Core Identity. Only its authentication ticket needs
    /// Keychain recovery; WebKit's persistent store remains authoritative for
    /// analytics, preferences and antiforgery cookies. Restoring an old
    /// antiforgery token alongside a fresh page can otherwise cause login
    /// loops or HTTP 400 responses.
    private static let recoverableCookieNames = [".AspNetCore.Identity.Application"]
    private static let sessionRecoveryTTL: TimeInterval = 30 * 24 * 60 * 60

    private let version: Int
    private let capturedAt: Date
    private let records: [CookieRecord]

    init(cookies: [HTTPCookie], now: Date = Date()) {
        version = Self.currentVersion
        capturedAt = now
        records = cookies
            .filter { Self.isRecoverableAuthenticationCookie($0) && !Self.isExpired($0, now: now) }
            .compactMap(CookieRecord.init)
            .sorted { $0.sortKey < $1.sortKey }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> MikanCookieArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let archive = try decoder.decode(Self.self, from: data)
        guard archive.version == currentVersion else {
            throw ArchiveError.unsupportedVersion(archive.version)
        }
        return archive
    }

    func cookies(now: Date = Date()) -> [HTTPCookie] {
        records.compactMap(\.cookie).filter {
            Self.isRecoverableAuthenticationCookie($0)
                && !Self.isExpired($0, now: now)
                && (!$0.isSessionOnly || now <= capturedAt.addingTimeInterval(Self.sessionRecoveryTTL))
        }
    }

/// Returns only cookies missing from WebKit. A cookie already present in
/// WebKit is newer ground truth and must never be replaced by stale
/// recovery copy.
static func restoreCandidates(archived: [HTTPCookie], existing: [HTTPCookie],
now: Date = Date()) -> [HTTPCookie] {
    let existingIDs = Set(existing
        .filter { isRecoverableAuthenticationCookie($0) && !isExpired($0, now: now) }
        .map(CookieIdentity.init))
    return archived.filter {
        isRecoverableAuthenticationCookie($0) && !isExpired($0, now: now)
        && !existingIDs.contains(CookieIdentity($0))
    }
}
static func isRecoverableAuthenticationCookie(_ cookie: HTTPCookie) -> Bool {
        isSupported(cookie) && recoverableCookieNames.contains(cookie.name)
    }

    static func isSupported(_ cookie: HTTPCookie) -> Bool {
        isSupported(host: cookie.domain)
    }

    static func isSupported(host: String) -> Bool {
        let host = normalizedDomain(host)
        return supportedDomains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private static func isExpired(_ cookie: HTTPCookie, now: Date) -> Bool {
        cookie.expiresDate.map { $0 <= now } ?? false
    }

    private static func normalizedDomain(_ domain: String) -> String {
        domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private struct CookieIdentity: Hashable {
        let name: String
        let domain: String
        let path: String

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            domain = MikanCookieArchive.normalizedDomain(cookie.domain)
            path = cookie.path
        }
    }

    private struct CookieRecord: Codable, Sendable {
        let name: String
        let domain: String
        let path: String
        private let properties: [String: PropertyValue]

        init?(_ cookie: HTTPCookie) {
            guard let sourceProperties = cookie.properties else { return nil }
            name = cookie.name
            domain = cookie.domain
            path = cookie.path
            var encodedProperties: [String: PropertyValue] = [:]
            for (key, sourceValue) in sourceProperties {
                // Fail closed rather than silently weakening a future cookie
                // property type that this archive version cannot represent.
                guard let value = PropertyValue(sourceValue) else { return nil }
                encodedProperties[key.rawValue] = value
            }
            properties = encodedProperties
        }

        var sortKey: String { "\(domain.lowercased())\u{0}\(path)\u{0}\(name)" }

        var cookie: HTTPCookie? {
            HTTPCookie(properties: properties.reduce(into: [:]) { result, item in
                result[HTTPCookiePropertyKey(item.key)] = item.value.foundationValue
            })
        }

        /// `HTTPCookie.properties` may include public Foundation property types
        /// plus WebKit-maintained keys such as HttpOnly. Preserve every value
        /// instead of reconstructing a weaker name/value-only cookie.
        private enum PropertyValue: Codable, Sendable {
            case string(String)
            case date(Date)
            case url(URL)
            case integer(Int64)
            case number(Double)
            case boolean(Bool)

            init?(_ value: Any) {
                switch value {
                case let value as String: self = .string(value)
                case let value as Date: self = .date(value)
                case let value as URL: self = .url(value)
                case let value as NSNumber:
                    if CFGetTypeID(value) == CFBooleanGetTypeID() {
                        self = .boolean(value.boolValue)
                        return
                    }
                    let double = value.doubleValue
                    if double.rounded() == double {
                        self = .integer(value.int64Value)
                    } else {
                        self = .number(double)
                    }
                case let value as Bool: self = .boolean(value)
                default: return nil
                }
            }

            var foundationValue: Any {
                switch self {
                case let .string(value): value
                case let .date(value): value
                case let .url(value): value
                case let .integer(value): NSNumber(value: value)
                case let .number(value): NSNumber(value: value)
                case let .boolean(value): NSNumber(value: value)
                }
            }
        }
    }

    enum ArchiveError: Error {
        case unsupportedVersion(Int)
    }
}

// MARK: - Sensitive storage

protocol MikanCookieArchiveStore: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func clear() throws
}


struct KeychainMikanCookieArchiveStore: MikanCookieArchiveStore {
    // Keep non-interactive v2 archive separate from legacy ad-hoc-build
    // keys that may request authentication.
    private static let primaryService = "iina-magnet.mikan.v2"
    private static let legacyServices = ["iina-magnet.mikan"]
    private let account = "cookies.v1"

    private var allServices: [String] { [Self.primaryService] + Self.legacyServices }

    private func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func queryCandidates(service: String) -> [[String: Any]] {
        [
            nonInteractiveQuery(service: service),
            baseQuery(service: service),
        ]
    }

    private func keychainQueryCandidates() -> [[String: Any]] {
        allServices.flatMap { queryCandidates(service: $0) }
    }

    private func nonInteractiveQuery(service: String) -> [String: Any] {
        var query = baseQuery(service: service)
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    private func primaryQueryCandidates() -> [[String: Any]] {
        queryCandidates(service: Self.primaryService)
    }

    func load() throws -> Data? {
        var lastError: OSStatus?

        for query in keychainQueryCandidates() {
            var lookup = query
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &item)
            guard status == errSecItemNotFound else {
                if status == errSecSuccess {
                    guard let data = item as? Data else {
                        throw KeychainError.operation("load", errSecInternalError)
                    }
                    return data
                }
                lastError = status
                continue
            }
        }

        if let lastError {
            throw KeychainError.operation("load", lastError)
        }
        return nil
    }

    func save(_ data: Data) throws {
        let changes = [kSecValueData as String: data]
        var lastError: OSStatus?

        for query in primaryQueryCandidates() {
            let updateStatus = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
            if updateStatus == errSecSuccess { return }
            if updateStatus == errSecItemNotFound { continue }
            lastError = updateStatus
        }

        for query in primaryQueryCandidates() {
            var item = query
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus == errSecSuccess { return }

            if addStatus == errSecDuplicateItem {
                let updateStatus = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
                if updateStatus == errSecSuccess { return }
                lastError = updateStatus
                continue
            }

            lastError = addStatus
        }

        throw KeychainError.operation("add", lastError ?? errSecInternalError)
    }

    func clear() throws {
        var lastError: OSStatus?

        for query in keychainQueryCandidates() {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound { continue }
            lastError = status
        }

        if let lastError {
            throw KeychainError.operation("delete", lastError)
        }
    }

    private enum KeychainError: LocalizedError {
        case operation(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case let .operation(operation, status):
                return "Mikan cookie Keychain \(operation) failed (OSStatus \(status))"
            }
        }
    }
}

private actor MikanCookieArchiveWorker {
    private let store: any MikanCookieArchiveStore

    init(store: any MikanCookieArchiveStore) { self.store = store }

    func load() throws -> Data? { try store.load() }
    func save(_ data: Data) throws { try store.save(data) }
    func clear() throws { try store.clear() }
}

// MARK: - WebKit synchronization

@MainActor
final class MikanCookiePersistence {
    private static let logger = Logger(subsystem: "iina-magnet", category: "mikan-cookies")
    private let archiveWorker: MikanCookieArchiveWorker
    private var snapshotGeneration = 0

    init(archiveStore: any MikanCookieArchiveStore = KeychainMikanCookieArchiveStore()) {
        archiveWorker = MikanCookieArchiveWorker(store: archiveStore)
    }

    /// Restores only authentication cookies still absent from WebKit and waits
    /// for every set-cookie completion. Cancellation is checked after every
    /// asynchronous boundary so startup can stay responsive while still honoring
    /// a completed cookie archive restore.
    @discardableResult
    func restoreMissingCookies(into cookieStore: WKHTTPCookieStore) async -> Int {
        await allowCookies(in: cookieStore)
        guard !Task.isCancelled else { return 0 }

        let archived: [HTTPCookie]
        do {
            guard let data = try await loadArchiveData() else { return 0 }
            archived = try MikanCookieArchive.decode(data).cookies()
        } catch let error as DecodingError {
            Self.logger.error("Mikan cookie archive decode failed: \(error.localizedDescription, privacy: .public)")
            // A corrupt archive must not trap every future launch.
            try? await clearArchiveData()
            return 0
        } catch let error as MikanCookieArchive.ArchiveError {
            Self.logger.error("Mikan cookie archive incompatible format: \(error.localizedDescription, privacy: .public)")
            try? await clearArchiveData()
            return 0
        } catch {
            Self.logger.error("Mikan cookie archive load failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }

        var restoredCount = 0
        for cookie in archived {
            guard !Task.isCancelled else { return restoredCount }
            // Re-read after Keychain and before every write. WebKit is the
            // current ground truth and may have received a newer auth cookie
            // while recovery was awaiting another subsystem.
            let existing = await allCookies(in: cookieStore)
            guard !Task.isCancelled else { return restoredCount }
            guard !MikanCookieArchive.restoreCandidates(
                archived: [cookie], existing: existing
            ).isEmpty else { continue }
            await set(cookie, in: cookieStore)
            restoredCount += 1
        }

        if restoredCount > 0 {
            Self.logger.info("Restored \(restoredCount, privacy: .public) Mikan cookie(s) before navigation")
        }
        return restoredCount
    }

    /// Captures the current WebKit state after login, rotation, logout, or
    /// expiry. Values are encrypted by Keychain and never logged.
    func snapshot(from cookieStore: WKHTTPCookieStore) async {
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        let cookies = await allCookies(in: cookieStore).filter(MikanCookieArchive.isSupported)
        guard !Task.isCancelled, generation == snapshotGeneration else { return }
        do {
            let archive = MikanCookieArchive(cookies: cookies)
            let restorable = archive.cookies()
            if restorable.isEmpty {
                try await clearArchiveData()
            } else {
                try await saveArchiveData(archive.encoded())
            }
            Self.logger.debug("Saved \(restorable.count, privacy: .public) Mikan cookie(s)")
        } catch {
            Self.logger.error("Mikan cookie snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes both live Mikan cookies and their recovery archive. This is the
    /// escape hatch for a server-revoked session that still has a future local
    /// expiry and therefore cannot be identified as stale from cookie metadata.
    func clearAllCookies(from cookieStore: WKHTTPCookieStore) async {
        snapshotGeneration &+= 1
        // A second pass closes the race with a response that was already
        // committing a rotated cookie when reset began.
        for _ in 0..<2 {
            let cookies = await allCookies(in: cookieStore).filter(MikanCookieArchive.isSupported)
            if cookies.isEmpty { break }
            for cookie in cookies {
                await delete(cookie, from: cookieStore)
            }
        }
        snapshotGeneration &+= 1
        do {
            try await clearArchiveData()
            Self.logger.info("Cleared Mikan login cookies and recovery archive")
        } catch {
            Self.logger.error("Mikan cookie reset failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func allCookies(in cookieStore: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private func set(_ cookie: HTTPCookie, in cookieStore: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            cookieStore.setCookie(cookie) { continuation.resume() }
        }
    }

    private func delete(_ cookie: HTTPCookie, from cookieStore: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            cookieStore.delete(cookie) { continuation.resume() }
        }
    }

    private func allowCookies(in cookieStore: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            cookieStore.setCookiePolicy(.allow) { continuation.resume() }
        }
    }

    private func loadArchiveData() async throws -> Data? {
        try await archiveWorker.load()
    }

    private func saveArchiveData(_ data: Data) async throws {
        try await archiveWorker.save(data)
    }

    private func clearArchiveData() async throws {
        try await archiveWorker.clear()
    }
}

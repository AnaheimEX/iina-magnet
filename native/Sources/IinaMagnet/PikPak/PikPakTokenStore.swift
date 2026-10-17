//
//  PikPakTokenStore.swift
//  IinaMagnet
//
//  The persisted PikPak auth session + storage backends. Tokens are sensitive,
//  so the default store is the macOS Keychain; tests use the in-memory store.

import Foundation
import LocalAuthentication
import OSLog
import Security

/// A signed-in PikPak session. `deviceID` is generated once and kept stable so
/// PikPak keeps recognizing this install across refreshes.
public struct PikPakSession: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var userID: String
    public var deviceID: String
    public var expiresAt: Date
    /// Last PikPak-minted captcha token. Persisted because drive calls need one
    /// and it cannot be derived from the tokens: without it the first call of a
    /// new launch fails with error_code 9 and (once PikPak has rotated the
    /// captcha salts) no self-signed replacement is accepted — which is what
    /// used to force a fresh login on every app start. Optional so sessions
    /// written by older builds still decode.
    public var captchaToken: String?
    /// When `captchaToken` was captured (diagnostics + staleness heuristics).
    public var captchaCapturedAt: Date?

    public init(accessToken: String, refreshToken: String, userID: String,
                deviceID: String, expiresAt: Date,
                captchaToken: String? = nil, captchaCapturedAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userID = userID
        self.deviceID = deviceID
        self.expiresAt = expiresAt
        self.captchaToken = captchaToken
        self.captchaCapturedAt = captchaCapturedAt
    }

    /// True within 60s of expiry, so callers refresh slightly early.
    public var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
}

public protocol PikPakTokenStore: Sendable {
    func load() -> PikPakSession?
    func save(_ session: PikPakSession)
    func clear()
}

// MARK: - Keychain (default)

// UserDefaults is thread-safe; Security calls are serialized by PikPakAuth.
public struct KeychainPikPakTokenStore: PikPakTokenStore, @unchecked Sendable {
    public static let persistenceFailureNotification = Notification.Name("PikPakPersistenceFailure")
    private static let logger = Logger(subsystem: "iina-magnet", category: "pikpak-store")
    private let service = "iina-magnet.pikpak"
    private let account = "session"
    private let fallbackKey = "iina-magnet.pikpak.fallback-session"
    private let signedOutKey = "iina-magnet.pikpak.signed-out"
    private let staleKey = "iina-magnet.pikpak.keychain-stale"
    private let defaults: UserDefaults
    private let keychain: PikPakKeychainAccess

    public init() {
        self.init(defaults: .standard, keychain: SystemPikPakKeychain())
    }

    init(defaults: UserDefaults, keychain: PikPakKeychainAccess) {
        self.defaults = defaults
        self.keychain = keychain
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private var nonInteractiveQuery: [String: Any] {
        var query = baseQuery
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    public func load() -> PikPakSession? {
        // A failed Keychain delete must not resurrect an explicitly cleared
        // session on the next launch.
        guard !defaults.bool(forKey: signedOutKey) else { return nil }

        guard !defaults.bool(forKey: staleKey) else { return nil }

        // One-time migration of the newest legacy replica. Never create new
        // plaintext copies; remove the legacy copy only after a secure write.
        if let data = defaults.data(forKey: fallbackKey),
           let session = try? JSONDecoder().decode(PikPakSession.self, from: data) {
            save(session)
            return session
        }

        var query = nonInteractiveQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = keychain.load(query)
        if status == errSecSuccess, let data = item {
            do {
                let session = try JSONDecoder().decode(PikPakSession.self, from: data)
                return session
            } catch {
                // Do not treat a storage read failure as an explicit sign-out.
                // The next successful save can replace this payload in place.
                Self.logger.error("Keychain payload undecodable")
            }
        } else if status != errSecItemNotFound {
            Self.logger.error("Keychain load failed (OSStatus \(status, privacy: .public))")
        }
        return nil
    }

    public func save(_ session: PikPakSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let changes: [String: Any] = [kSecValueData as String: data]
        // A user-approved Keychain prompt is preferable to a plaintext replica.
        var status = keychain.update(baseQuery, changes: changes)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = false
            status = keychain.add(add)
            if status == errSecDuplicateItem { status = keychain.update(baseQuery, changes: changes) }
        }
        if status == errSecSuccess {
            defaults.removeObject(forKey: fallbackKey)
            defaults.removeObject(forKey: staleKey)
            defaults.removeObject(forKey: signedOutKey)
        } else {
            defaults.set(true, forKey: staleKey)
            Self.logger.error("Keychain save failed (OSStatus \(status, privacy: .public)); session remains in memory only")
            NotificationCenter.default.post(name: Self.persistenceFailureNotification, object: nil)
        }
    }

    public func clear() {
        defaults.set(true, forKey: signedOutKey)
        defaults.removeObject(forKey: fallbackKey)
        defaults.removeObject(forKey: staleKey)
        let status = keychain.delete(nonInteractiveQuery)
        if status != errSecSuccess, status != errSecItemNotFound {
            Self.logger.error("Keychain clear failed (OSStatus \(status, privacy: .public))")
        }
    }
}

/// Security.framework boundary, injectable without touching the user's Keychain.
protocol PikPakKeychainAccess: Sendable {
    func load(_ query: [String: Any]) -> (OSStatus, Data?)
    func update(_ query: [String: Any], changes: [String: Any]) -> OSStatus
    func add(_ query: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct SystemPikPakKeychain: PikPakKeychainAccess {
    func load(_ query: [String: Any]) -> (OSStatus, Data?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    func update(_ query: [String: Any], changes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, changes as CFDictionary)
    }

    func add(_ query: [String: Any]) -> OSStatus {
        SecItemAdd(query as CFDictionary, nil)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - In-memory (tests)

public final class InMemoryPikPakTokenStore: PikPakTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: PikPakSession?

    public init(_ initial: PikPakSession? = nil) { self.session = initial }

    public func load() -> PikPakSession? { lock.withLock { session } }
    public func save(_ session: PikPakSession) { lock.withLock { self.session = session } }
    public func clear() { lock.withLock { session = nil } }
}

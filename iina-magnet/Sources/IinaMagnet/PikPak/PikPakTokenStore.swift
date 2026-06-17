//
//  PikPakTokenStore.swift
//  IinaMagnet
//
//  The persisted PikPak auth session + storage backends. Tokens are sensitive,
//  so the default store is the macOS Keychain; tests use the in-memory store.

import Foundation
import Security

/// A signed-in PikPak session. `deviceID` is generated once and kept stable so
/// PikPak keeps recognizing this install across refreshes.
public struct PikPakSession: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var userID: String
    public var deviceID: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, userID: String,
                deviceID: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userID = userID
        self.deviceID = deviceID
        self.expiresAt = expiresAt
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

public struct KeychainPikPakTokenStore: PikPakTokenStore {
    private let service = "iina-magnet.pikpak"
    private let account = "session"

    public init() {}

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> PikPakSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PikPakSession.self, from: data)
    }

    public func save(_ session: PikPakSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            print("PikPakTokenStore failed to save to Keychain: \(status)")
        }
    }

    public func clear() {
        SecItemDelete(baseQuery as CFDictionary)
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

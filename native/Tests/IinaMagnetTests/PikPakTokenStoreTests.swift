import Foundation
import LocalAuthentication
import Security
import Testing
@testable import IinaMagnet

@Suite struct PikPakTokenStoreTests {
    @Test func failedRotationSaveNeverRestoresStaleOrPlaintextTokens() async throws {
        let fixture = StoreFixture()
        let auth = PikPakAuth(store: fixture.store())
        await auth.adopt(credentials("old"))
        fixture.keychain.writeStatus = errSecInteractionNotAllowed
        await auth.adopt(credentials("rotated"))

        // The active process retains the new token, but a subsequent launch
        // must not revive the old Keychain token or rely on a plaintext copy.
        #expect(try await auth.validAccessToken() == "access-rotated")
        let relaunched = PikPakAuth(store: fixture.store())
        #expect(await relaunched.isSignedIn == false)
        #expect(fixture.store().load() == nil)
        #expect(UserDefaults(suiteName: fixture.suiteName)?.data(forKey: "iina-magnet.pikpak.fallback-session") == nil)
        #expect(fixture.keychain.deleteCount == 0)
    }

    @Test func corruptKeychainDoesNotDeleteTheStoredItem() throws {
        let fixture = StoreFixture()
        fixture.store().save(session("saved"))
        fixture.keychain.data = Data("corrupt".utf8)
        #expect(fixture.store().load() == nil)
        #expect(fixture.keychain.deleteCount == 0)
    }

    @Test func explicitSignOutSurvivesFailedKeychainDelete() {
        let fixture = StoreFixture()
        fixture.store().save(session("old"))
        fixture.keychain.writeStatus = errSecInteractionNotAllowed
        fixture.store().clear()
        fixture.keychain.writeStatus = errSecSuccess
        #expect(fixture.store().load() == nil)

        fixture.store().save(session("new"))
        #expect(fixture.store().load() == session("new"))
    }

    @Test func unavailableKeychainDoesNotUsePlaintextReplica() {
        let fixture = StoreFixture()
        fixture.store().save(session("saved"))
        fixture.keychain.readStatus = errSecInteractionNotAllowed
        #expect(fixture.store().load() == nil)
    }

    @Test func backgroundReadsAndDeletesDoNotRequestInteractiveAuthentication() {
        let fixture = StoreFixture()
        _ = fixture.store().load()
        fixture.store().save(session("saved"))
        fixture.store().clear()
        #expect(!fixture.keychain.queries.isEmpty)
        for query in [fixture.keychain.queries.first!, fixture.keychain.queries.last!] {
            let context = query[kSecUseAuthenticationContext as String] as? LAContext
            #expect(context?.interactionNotAllowed == true)
        }
    }

    @Test func keychainOnlySessionStillRestores() throws {
        let fixture = StoreFixture()
        fixture.keychain.data = try JSONEncoder().encode(session("keychain"))
        #expect(fixture.store().load() == session("keychain"))
    }

    private func credentials(_ value: String) -> PikPakWebCredentials {
        PikPakWebCredentials(accessToken: "access-\(value)", refreshToken: "refresh-\(value)",
                             userID: "user", deviceID: "device", expiresIn: 7200,
                             captchaToken: "captcha-\(value)")
    }

    private func session(_ value: String) -> PikPakSession {
        PikPakSession(accessToken: "access-\(value)", refreshToken: "refresh-\(value)",
                      userID: "user", deviceID: "device",
                      expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
                      captchaToken: "captcha-\(value)")
    }
}

private final class StoreFixture {
    let suiteName = "iina-magnet.pikpak-tests.\(UUID().uuidString)"
    let keychain = StubKeychain()

    func store() -> KeychainPikPakTokenStore {
        // A fresh defaults object and token store model the next app launch.
        KeychainPikPakTokenStore(defaults: UserDefaults(suiteName: suiteName)!, keychain: keychain)
    }

    deinit { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
}

private final class StubKeychain: PikPakKeychainAccess, @unchecked Sendable {
    var data: Data?
    var readStatus: OSStatus = errSecSuccess
    var writeStatus: OSStatus = errSecSuccess
    var deleteCount = 0
    var queries: [[String: Any]] = []

    func load(_ query: [String: Any]) -> (OSStatus, Data?) {
        queries.append(query)
        guard readStatus == errSecSuccess else { return (readStatus, nil) }
        return (data == nil ? errSecItemNotFound : errSecSuccess, data)
    }

    func update(_ query: [String: Any], changes: [String: Any]) -> OSStatus {
        queries.append(query)
        guard writeStatus == errSecSuccess else { return writeStatus }
        guard data != nil else { return errSecItemNotFound }
        data = changes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func add(_ query: [String: Any]) -> OSStatus {
        queries.append(query)
        guard writeStatus == errSecSuccess else { return writeStatus }
        guard data == nil else { return errSecDuplicateItem }
        data = query[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        queries.append(query)
        deleteCount += 1
        guard writeStatus == errSecSuccess else { return writeStatus }
        data = nil
        return errSecSuccess
    }
}

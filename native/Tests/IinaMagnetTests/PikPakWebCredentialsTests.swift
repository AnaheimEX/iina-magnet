//
//  PikPakWebCredentialsTests.swift
//  IinaMagnetTests
//
//  Parsing tokens out of the web client's localStorage (the web-view login
//  path) + adopting them as a session. Synthetic tokens only — no real creds.

import Testing
import Foundation
@testable import IinaMagnet

private let dev = "0123456789abcdef0123456789abcdef"   // 32 hex, device-id shaped

@Suite struct PikPakWebCredentialParserTests {

    @Test func flatKeys() throws {
        let json = """
        {"access_token":"acc","refresh_token":"ref","sub":"u-1","device_id":"\(dev)","expires_in":7200}
        """
        let c = try #require(PikPakWebCredentialParser.parse(localStorageJSON: json))
        #expect(c.accessToken == "acc")
        #expect(c.refreshToken == "ref")
        #expect(c.userID == "u-1")
        #expect(c.deviceID == dev)
        #expect(c.expiresIn == 7200)
    }

    @Test func nestedCredentialBlobWithSeparateDeviceKey() throws {
        // localStorage value is itself a JSON string; device id lives elsewhere.
        let blob = #"{\"access_token\":\"a2\",\"refresh_token\":\"r2\",\"sub\":\"u-2\",\"expires_in\":3600}"#
        let json = "{\"credentials\":\"\(blob)\",\"deviceid\":\"\(dev)\"}"
        let c = try #require(PikPakWebCredentialParser.parse(localStorageJSON: json))
        #expect(c.accessToken == "a2")
        #expect(c.refreshToken == "r2")
        #expect(c.userID == "u-2")
        #expect(c.deviceID == dev)            // recovered from the "deviceid" key
        #expect(c.expiresIn == 3600)
    }

    @Test func camelCaseKeysAndStringExpiry() throws {
        let json = """
        {"accessToken":"a3","refreshToken":"r3","userId":"u-3","expiresIn":"600"}
        """
        let c = try #require(PikPakWebCredentialParser.parse(localStorageJSON: json))
        #expect(c.accessToken == "a3")
        #expect(c.refreshToken == "r3")
        #expect(c.userID == "u-3")
        #expect(c.expiresIn == 600)
        #expect(c.deviceID == nil)
    }

    @Test func deviceIDFallbackFromDeviceShapedKey() throws {
        let json = """
        {"access_token":"a","refresh_token":"r","x-device-id":"\(dev)"}
        """
        let c = try #require(PikPakWebCredentialParser.parse(localStorageJSON: json))
        #expect(c.deviceID == dev)
    }

    @Test func missingRefreshTokenYieldsNil() {
        let json = #"{"access_token":"only-access","sub":"u"}"#
        #expect(PikPakWebCredentialParser.parse(localStorageJSON: json) == nil)
    }

    @Test func garbageOrEmptyYieldsNil() {
        #expect(PikPakWebCredentialParser.parse(localStorageJSON: "") == nil)
        #expect(PikPakWebCredentialParser.parse(localStorageJSON: "not json") == nil)
        #expect(PikPakWebCredentialParser.parse(localStorageJSON: "{}") == nil)
        #expect(PikPakWebCredentialParser.parse(localStorageJSON: #"{"foo":"bar"}"#) == nil)
    }
}

@Suite struct PikPakAdoptTests {

    @Test func adoptPersistsAndAuthenticates() async throws {
        let store = InMemoryPikPakTokenStore()
        let auth = PikPakAuth(config: .web, http: URLSessionPikPakClient(), store: store)
        let cred = PikPakWebCredentials(accessToken: "acc", refreshToken: "ref",
                                        userID: "u-9", deviceID: dev, expiresIn: 7200)
        await auth.adopt(cred)

        #expect(await auth.isSignedIn)
        #expect(await auth.userID == "u-9")
        #expect(try await auth.validAccessToken() == "acc")   // not expired, no network
        let saved = try #require(store.load())
        #expect(saved.refreshToken == "ref")
        #expect(saved.deviceID == dev)
    }

    @Test func adoptWithoutDeviceIDMintsOne() async throws {
        let store = InMemoryPikPakTokenStore()
        let auth = PikPakAuth(config: .web, http: URLSessionPikPakClient(), store: store)
        await auth.adopt(PikPakWebCredentials(accessToken: "a", refreshToken: "r",
                                              userID: "u", deviceID: nil, expiresIn: nil))
        let saved = try #require(store.load())
        #expect(saved.deviceID.count == 32)            // minted a device id
    }
}

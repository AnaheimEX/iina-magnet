//
//  LibtorrentBridgeTests.swift
//  LibtorrentBridgeTests
//
//  Smoke tests for the Obj-C++ wrapper. Network-free: only exercises
//  session construction + invalid inputs. Real downloading is covered
//  by the Swift TorrentManager integration test (Issue 06) which uses
//  a local tracker fixture.

import Testing
import Foundation
@testable import LibtorrentBridge

@Suite("LibtorrentBridge — Phase 1 smoke")
struct LibtorrentBridgeSmoke {

    @Test("Session can be constructed with default settings")
    func sessionConstructs() {
        let settings = LMSessionSettings.default()
        #expect(settings.enableDHT == true)
        #expect(settings.enableUPnP == false)
        let session = LMSession(settings: settings)
        _ = session  // ensure init returns
    }

    @Test("addMagnet rejects an obviously invalid URI")
    func invalidMagnetRejected() {
        let session = LMSession(settings: .default())
        // NSError** in Obj-C is bridged to Swift as throws; invalid URI throws.
        #expect(throws: (any Error).self) {
            _ = try session.addMagnet("not-a-magnet", savePath: NSTemporaryDirectory())
        }
    }

    @Test("addMagnet accepts a valid Ubuntu-style magnet URI and returns its v1 info-hash")
    func validMagnetReturnsHash() throws {
        let session = LMSession(settings: .default())
        // Public Ubuntu LTS magnet — info-hash is deterministic.
        let magnet = "magnet:?xt=urn:btih:9f9165d9a281a9b8e782cd5176bbcc8256fd1871"
        let hash = try session.addMagnet(magnet, savePath: NSTemporaryDirectory())
        #expect(hash.count == 40)  // SHA-1 hex
        #expect(hash.lowercased() == "9f9165d9a281a9b8e782cd5176bbcc8256fd1871")

        // pumpAlerts should not crash on a freshly added torrent (might have no alerts yet).
        _ = session.pumpAlerts()
    }

    @Test("pumpAlerts on empty session returns empty array")
    func pumpAlertsEmpty() {
        let session = LMSession(settings: .default())
        let alerts = session.pumpAlerts()
        #expect(alerts.isEmpty)
    }

    @Test("statusOf returns nil for unknown info-hash")
    func statusUnknownReturnsNil() {
        let session = LMSession(settings: .default())
        let s = session.status(of: "0000000000000000000000000000000000000000")
        #expect(s == nil)
    }
}

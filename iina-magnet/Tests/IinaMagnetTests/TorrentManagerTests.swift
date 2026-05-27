//
//  TorrentManagerTests.swift
//  IinaMagnetTests
//
//  Smoke tests for the Swift actor. End-to-end download flows are deferred
//  to a network-capable integration target; here we cover:
//    - Bootstrap lifecycle (start / shutdown idempotent)
//    - Magnet add → TorrentTask row inserted in SwiftData
//    - Remove → TorrentTask row deleted
//    - Events stream subscription doesn't crash on empty session

import Testing
import Foundation
import SwiftData
@testable import IinaMagnet
import LibtorrentBridge

@Suite("TorrentManager — Phase 1 smoke")
struct TorrentManagerTests {

    private func makeManager() -> (TorrentManager, PersistenceController) {
        let persistence = PersistenceController.inMemory()
        let session = LMSession(settings: .default())
        let manager = TorrentManager(session: session, persistence: persistence)
        return (manager, persistence)
    }

    @Test("Lifecycle: start then shutdown is idempotent")
    func lifecycle() async {
        let (manager, _) = makeManager()
        await manager.start()
        await manager.start()       // second call no-ops
        await manager.shutdown()
        await manager.shutdown()    // second call no-ops
    }

    @Test("addMagnet inserts a TorrentTask row")
    func addMagnetPersists() async throws {
        let (manager, persistence) = makeManager()
        await manager.start()

        let magnet = "magnet:?xt=urn:btih:9f9165d9a281a9b8e782cd5176bbcc8256fd1871"
        let hash = try await manager.addMagnet(magnet, savePath: URL(fileURLWithPath: NSTemporaryDirectory()))

        #expect(hash.hex.count == 40)

        let ctx = ModelContext(persistence.container)
        let tasks = try ctx.fetch(FetchDescriptor<TorrentTask>())
        #expect(tasks.count == 1)
        #expect(tasks.first?.infoHash == hash.hex)
        #expect(tasks.first?.status == .resolving)

        await manager.shutdown()
    }

    @Test("remove deletes the TorrentTask row")
    func removeDeletes() async throws {
        let (manager, persistence) = makeManager()
        await manager.start()

        let magnet = "magnet:?xt=urn:btih:9f9165d9a281a9b8e782cd5176bbcc8256fd1871"
        let hash = try await manager.addMagnet(magnet, savePath: URL(fileURLWithPath: NSTemporaryDirectory()))
        await manager.remove(hash, deleteFiles: false)

        let ctx = ModelContext(persistence.container)
        let tasks = try ctx.fetch(FetchDescriptor<TorrentTask>())
        #expect(tasks.isEmpty)

        await manager.shutdown()
    }

    @Test("events() returns a usable stream")
    func eventsStreamSubscribable() async {
        let (manager, _) = makeManager()
        await manager.start()

        let stream = manager.events()
        // Just verify subscription doesn't crash and termination is clean.
        let iter = Task { [stream] in
            var first: TorrentEvent?
            for await ev in stream {
                first = ev
                break
            }
            return first
        }
        // We can't reliably wait for an event in a synthetic session; cancel.
        iter.cancel()
        _ = await iter.value

        await manager.shutdown()
    }
}

//
//  SmokeTest.swift
//  IinaMagnetTests
//
//  Phase 0 baseline test — ensures the package compiles and the Bootstrap +
//  PersistenceController lifecycle works. Replace / expand as subsystems land.

import Testing
@testable import IinaMagnet

@Suite("IinaMagnet — Phase 0 smoke")
struct SmokeTest {

    @Test("Bootstrap.start / shutdown is idempotent")
    func bootstrapLifecycle() {
        IinaMagnetBootstrap.start()
        IinaMagnetBootstrap.start()   // second call is a no-op
        IinaMagnetBootstrap.shutdown()
        IinaMagnetBootstrap.shutdown() // second call is a no-op
    }

    @Test("In-memory PersistenceController opens with empty schema")
    func emptyContainerOpens() async throws {
        let controller = PersistenceController.inMemory()
        #expect(controller.container.configurations.first?.isStoredInMemoryOnly == true)
    }
}

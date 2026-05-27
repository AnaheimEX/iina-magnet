//
//  SmokeTest.swift
//  IinaMagnetTests
//
//  Phase 0 baseline test — ensures the package compiles and the Bootstrap +
//  PersistenceController lifecycle works. Replace / expand as subsystems land.

import Testing
@testable import IinaMagnet

@Suite("IinaMagnet — Phase 0 smoke")
@MainActor
struct SmokeTest {

    @Test("Bootstrap.shutdown is safe to call without prior start")
    func bootstrapShutdownIdempotent() {
        // We don't call start() here because Phase 0's start installs an NSApp
        // main menu — and NSApp is nil in `swift test` headless mode. The full
        // start path is exercised by the integration test inside the iina .app.
        IinaMagnetBootstrap.shutdown()
        IinaMagnetBootstrap.shutdown() // safe second call
    }

    @Test("In-memory PersistenceController opens with Phase 0 schema")
    func inMemoryContainerOpens() async throws {
        let controller = PersistenceController.inMemory()
        #expect(controller.container.configurations.first?.isStoredInMemoryOnly == true)
    }
}

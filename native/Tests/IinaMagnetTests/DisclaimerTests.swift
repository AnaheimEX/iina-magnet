//
//  DisclaimerTests.swift
//  IinaMagnetTests
//
//  Unit tests for DisclaimerCoordinator. UI (DisclaimerSheet) is not unit-tested
//  in Phase 0; manual verification covers it until Issue 03 wires it into AppDelegate.

import Testing
import Foundation
import SwiftData
@testable import IinaMagnet

@Suite("DisclaimerCoordinator")
@MainActor
struct DisclaimerCoordinatorTests {

    private func makeInMemoryCoordinator() throws -> (DisclaimerCoordinator, ModelContext) {
        let schema = Schema([DisclaimerAcceptance.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let ctx = ModelContext(container)
        return (DisclaimerCoordinator(context: ctx), ctx)
    }

    @Test("Fresh database needs acceptance")
    func needsAcceptanceOnEmptyDB() throws {
        let (coord, _) = try makeInMemoryCoordinator()
        #expect(coord.needsAcceptance() == true)
    }

    @Test("After accept(), needsAcceptance returns false")
    func acceptFlipsTheFlag() throws {
        let (coord, _) = try makeInMemoryCoordinator()
        try coord.accept()
        #expect(coord.needsAcceptance() == false)
    }

    @Test("Accept inserts exactly one row with the current version")
    func acceptInsertsRow() throws {
        let (coord, ctx) = try makeInMemoryCoordinator()
        try coord.accept()

        let all = try ctx.fetch(FetchDescriptor<DisclaimerAcceptance>())
        #expect(all.count == 1)
        #expect(all.first?.version == DisclaimerCoordinator.currentVersion)
    }

    @Test("Stale acceptance of a different version still triggers needsAcceptance")
    func staleVersionTriggersReprompt() throws {
        let (coord, ctx) = try makeInMemoryCoordinator()
        let oldAcceptance = DisclaimerAcceptance(version: "1999-01-01", acceptedAt: .now)
        ctx.insert(oldAcceptance)
        try ctx.save()

        #expect(coord.needsAcceptance() == true)
    }

    @Test("currentVersion is non-empty and stable enough to use as a key")
    func currentVersionShape() {
        #expect(DisclaimerCoordinator.currentVersion.isEmpty == false)
        #expect(DisclaimerCoordinator.currentVersion.contains("-"))
    }
}

@Suite("Disclaimer markdown loading")
@MainActor
struct DisclaimerMarkdownTests {

    @Test("zh-Hans markdown loads from the bundle")
    func chineseMarkdownLoads() {
        let attr = DisclaimerSheet.loadMarkdown(named: "Disclaimer.zh-Hans")
        #expect(attr != nil)
        // Sanity check: contains a marker word we know is in the canonical text.
        let plain = attr.map { String($0.characters) } ?? ""
        #expect(plain.contains("免责"))
    }

    @Test("en markdown loads from the bundle")
    func englishMarkdownLoads() {
        let attr = DisclaimerSheet.loadMarkdown(named: "Disclaimer.en")
        #expect(attr != nil)
        let plain = attr.map { String($0.characters) } ?? ""
        #expect(plain.contains("Disclaimer"))
    }
}

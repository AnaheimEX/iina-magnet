//
//  LibraryItemCacheTests.swift
//  IinaMagnetTests
//
//  Memoization: a Title's view model is reused while updatedAt is unchanged and
//  rebuilt when it bumps; removed Titles are evicted.

import Testing
import Foundation
import SwiftData
@testable import IinaMagnet

@Suite("LibraryItemCache", .serialized)
struct LibraryItemCacheTests {

    @Test("reuses the VM until updatedAt changes, then rebuilds")
    func memoizesByUpdatedAt() {
        let ctx = ModelContext(PersistenceController.inMemory().container)
        let t = Title(kind: .tv, titleZh: "A", matchState: .confirmed)
        ctx.insert(t)
        let cache = LibraryItemCache()

        #expect(cache.items(for: [t]).first?.titleZh == "A")

        // Mutate the field but NOT updatedAt → memoized, returns the stale VM.
        t.titleZh = "B"
        #expect(cache.items(for: [t]).first?.titleZh == "A")

        // Bump updatedAt → cache invalidates, rebuilds with the new value.
        t.updatedAt = t.updatedAt.addingTimeInterval(1)
        #expect(cache.items(for: [t]).first?.titleZh == "B")
    }

    @Test("evicts entries for titles no longer present")
    func evictsRemoved() {
        let ctx = ModelContext(PersistenceController.inMemory().container)
        let t = Title(kind: .tv, titleZh: "A", matchState: .confirmed)
        ctx.insert(t)
        let cache = LibraryItemCache()

        _ = cache.items(for: [t])           // cached
        _ = cache.items(for: [])            // t evicted

        // Mutate without bumping updatedAt; since the entry was evicted, the next
        // build is fresh (reflects the new value) rather than a stale hit.
        t.titleZh = "C"
        #expect(cache.items(for: [t]).first?.titleZh == "C")
    }

    @Test("preserves order and handles a mixed changed/unchanged batch")
    func mixedBatch() {
        let ctx = ModelContext(PersistenceController.inMemory().container)
        let a = Title(kind: .tv, titleZh: "a", matchState: .confirmed)
        let b = Title(kind: .tv, titleZh: "b", matchState: .confirmed)
        ctx.insert(a); ctx.insert(b)
        let cache = LibraryItemCache()

        #expect(cache.items(for: [a, b]).map(\.titleZh) == ["a", "b"])

        b.titleZh = "b2"; b.updatedAt = b.updatedAt.addingTimeInterval(1)  // only b changes
        a.titleZh = "a2"                                                   // a stale (no bump)
        #expect(cache.items(for: [a, b]).map(\.titleZh) == ["a", "b2"])
    }
}

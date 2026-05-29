//
//  MetadataCacheTests.swift
//  IinaMagnetTests
//
//  24h details cache (Issue 05): store/retrieve, TTL expiry, upsert, and the
//  CachingMetadataProvider decorator serving the second `details` from cache.

import Testing
import Foundation
import SwiftData
@testable import IinaMagnet

@Suite("MetadataCache", .serialized)
struct MetadataCacheTests {

    private func details(_ id: String, title: String) -> MetadataDetails {
        MetadataDetails(providerId: .bangumi, externalId: id, titleZh: title,
                        releaseYear: 2023, rating: 8.9,
                        episodes: [.init(number: 1, title: "第一集")])
    }

    @Test("store then retrieve within TTL round-trips")
    func roundTrip() async {
        let store = MetadataCacheStore(container: PersistenceController.inMemory().container)
        let key = MetadataCacheStore.key(provider: .bangumi, externalId: "459283")
        #expect(await store.details(forKey: key) == nil)

        await store.store(details("459283", title: "葬送的芙莉莲"), forKey: key)
        let got = await store.details(forKey: key)
        #expect(got?.titleZh == "葬送的芙莉莲")
        #expect(got?.episodes.first?.title == "第一集")
    }

    @Test("entries past the TTL are treated as misses")
    func expiry() async {
        let store = MetadataCacheStore(container: PersistenceController.inMemory().container,
                                       ttl: 60)
        let key = MetadataCacheStore.key(provider: .bangumi, externalId: "1")
        let stored = Date(timeIntervalSince1970: 1_000)
        await store.store(details("1", title: "X"), forKey: key, now: stored)

        // 30s later → hit; 120s later → expired miss.
        #expect(await store.details(forKey: key, now: stored.addingTimeInterval(30)) != nil)
        #expect(await store.details(forKey: key, now: stored.addingTimeInterval(120)) == nil)
    }

    @Test("re-storing the same key upserts (no duplicate row)")
    func upsert() async throws {
        let container = PersistenceController.inMemory().container
        let store = MetadataCacheStore(container: container)
        let key = MetadataCacheStore.key(provider: .bangumi, externalId: "1")
        await store.store(details("1", title: "旧"), forKey: key)
        await store.store(details("1", title: "新"), forKey: key)

        let ctx = ModelContext(container)
        #expect(try ctx.fetch(FetchDescriptor<MetadataCache>()).count == 1)
        #expect(await store.details(forKey: key)?.titleZh == "新")
    }

    /// Counts how many times `details` actually hits the network.
    private actor CountingProvider: MetadataProvider {
        let id: ProviderID = .bangumi
        private(set) var detailCalls = 0
        nonisolated func search(_ query: SearchQuery) async throws -> [MetadataCandidate] { [] }
        func details(externalId: String) async throws -> MetadataDetails {
            detailCalls += 1
            return MetadataDetails(providerId: .bangumi, externalId: externalId, titleZh: "T")
        }
        func calls() -> Int { detailCalls }
    }

    @Test("CachingMetadataProvider serves the second details from cache")
    func decoratorCaches() async throws {
        let inner = CountingProvider()
        let cache = MetadataCacheStore(container: PersistenceController.inMemory().container)
        let provider = CachingMetadataProvider(inner, cache: cache)

        let first = try await provider.details(externalId: "459283")
        let second = try await provider.details(externalId: "459283")
        #expect(first.titleZh == "T")
        #expect(second.titleZh == "T")
        #expect(await inner.calls() == 1)   // network hit once; second served from cache
    }
}

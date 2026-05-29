//
//  CachingMetadataProvider.swift
//  IinaMagnet
//
//  Decorator that serves `details` from a MetadataCacheStore (24h TTL) before
//  falling back to the wrapped provider, then caches the fresh result. `search`
//  passes straight through for now (candidates are a single cheap call and the
//  candidate type isn't Codable yet — caching search is a follow-up).

import Foundation

public struct CachingMetadataProvider: MetadataProvider {

    private let inner: MetadataProvider
    private let cache: MetadataCacheStore

    public init(_ inner: MetadataProvider, cache: MetadataCacheStore) {
        self.inner = inner
        self.cache = cache
    }

    public var id: ProviderID { inner.id }

    public func search(_ query: SearchQuery) async throws -> [MetadataCandidate] {
        try await inner.search(query)
    }

    public func details(externalId: String) async throws -> MetadataDetails {
        let key = MetadataCacheStore.key(provider: inner.id, externalId: externalId)
        if let cached = await cache.details(forKey: key) {
            return cached
        }
        let fresh = try await inner.details(externalId: externalId)
        await cache.store(fresh, forKey: key)
        return fresh
    }
}

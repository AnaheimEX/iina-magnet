//
//  MetadataCache.swift
//  IinaMagnet
//
//  24h LRU cache of provider responses (Phase 2, Issue 01; populated by Issue 05).
//  `cacheKey` = "<providerId>|<externalId>|<locale>"; `payload` is the encoded
//  MetadataDetails (Issue 05 defines the type — stored as opaque Data here).

import Foundation
import SwiftData

@Model
public final class MetadataCache {

    @Attribute(.unique) public var cacheKey: String
    public var payload: Data
    public var fetchedAt: Date

    public init(cacheKey: String, payload: Data, fetchedAt: Date = .now) {
        self.cacheKey = cacheKey
        self.payload = payload
        self.fetchedAt = fetchedAt
    }
}

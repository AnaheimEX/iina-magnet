//
//  MetadataCacheStore.swift
//  IinaMagnet
//
//  24h cache of provider `details` responses (Issue 05), so a re-scan doesn't
//  re-hit the network for subjects we already resolved. Backed by the
//  MetadataCache @Model (cacheKey unique). The store is an actor that solely
//  owns its ModelContext, keeping all SwiftData access on one isolation domain
//  (the context never crosses an actor boundary).

import Foundation
import SwiftData
import OSLog

public actor MetadataCacheStore {

    private static let logger = Logger(subsystem: "iina-magnet", category: "metadata-cache")

    /// Process-wide store over the app's shared container. Share ONE instance so
    /// the actor serializes upserts on a single context — separate stores (each
    /// with its own context) could otherwise race on the unique `cacheKey` insert
    /// and silently drop a write. Tests construct their own with explicit
    /// in-memory containers, so this lazy singleton never opens the disk store
    /// during testing.
    public static let shared = MetadataCacheStore(container: PersistenceController.shared.container)

    private let context: ModelContext
    private let ttl: TimeInterval

    /// - Parameters:
    ///   - container: the shared ModelContainer; a dedicated context is created.
    ///   - ttl: entries older than this are treated as misses (default 24h).
    public init(container: ModelContainer, ttl: TimeInterval = 24 * 60 * 60) {
        self.context = ModelContext(container)
        self.ttl = ttl
    }

    /// cacheKey convention: "<providerId>|<externalId>|<locale>".
    public static func key(provider: ProviderID, externalId: String, locale: String = "zh") -> String {
        "\(provider.rawValue)|\(externalId)|\(locale)"
    }

    /// Returns the cached details if present and within TTL; otherwise nil
    /// (expired rows are dropped so the store doesn't grow unbounded).
    public func details(forKey key: String, now: Date = .now) -> MetadataDetails? {
        guard let row = fetch(key) else { return nil }
        if now.timeIntervalSince(row.fetchedAt) > ttl {
            context.delete(row)
            try? context.save()
            return nil
        }
        return try? JSONDecoder().decode(MetadataDetails.self, from: row.payload)
    }

    /// Upserts the cached details under `key`, refreshing `fetchedAt`.
    public func store(_ details: MetadataDetails, forKey key: String, now: Date = .now) {
        guard let payload = try? JSONEncoder().encode(details) else { return }
        if let row = fetch(key) {
            row.payload = payload
            row.fetchedAt = now
        } else {
            context.insert(MetadataCache(cacheKey: key, payload: payload, fetchedAt: now))
        }
        do { try context.save() }
        catch { Self.logger.error("cache save failed: \(error.localizedDescription, privacy: .public)") }
    }

    private func fetch(_ key: String) -> MetadataCache? {
        var d = FetchDescriptor<MetadataCache>(predicate: #Predicate { $0.cacheKey == key })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }
}

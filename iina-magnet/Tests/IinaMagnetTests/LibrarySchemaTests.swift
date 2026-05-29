//
//  LibrarySchemaTests.swift
//  IinaMagnetTests
//
//  CRUD + relationship + constraint tests for the Phase 2 media-library schema
//  (Issue 01). Exercises the full PersistenceController schema (Phase 1 + Phase 2)
//  to catch cross-entity issues.
//
//  Uses `ModelContext(container)` rather than `container.mainContext` (matching
//  the Phase 1 test style): the CLI swift-testing toolchain on this host traps
//  inside `.mainContext` save, unrelated to the schema — `ModelContext` is the
//  isolated-per-test idiom anyway.

import Testing
import Foundation
import SwiftData
@testable import IinaMagnet

@Suite("LibrarySchema", .serialized)
struct LibrarySchemaTests {

    private func makeContext() -> ModelContext {
        ModelContext(PersistenceController.inMemory().container)
    }

    @Test("Title → Season → Episode → VersionFile chain persists and queries back")
    func cascadeChainPersists() throws {
        let ctx = makeContext()

        let title = Title(kind: .tv, titleZh: "葬送的芙莉莲", releaseYear: 2023,
                          matchState: .confirmed, matchScore: 0.97)
        let season = Season(number: 1)
        let ep = Episode(number: 1, seasonNumber: 1, title: "旅途的终点")
        let v = VersionFile(fileURL: URL(fileURLWithPath: "/tmp/frieren-s01e01-1080p.mkv"),
                            fileFingerprint: "1:1001:12345",
                            fileSizeBytes: 12345,
                            resolution: "1080p",
                            releaseGroup: "LoliHouse")
        ep.versions.append(v)
        season.episodes.append(ep)
        title.seasons.append(season)
        ctx.insert(title)
        try ctx.save()

        let titles = try ctx.fetch(FetchDescriptor<Title>())
        #expect(titles.count == 1)
        let fetched = try #require(titles.first)
        #expect(fetched.titleZh == "葬送的芙莉莲")
        #expect(fetched.kind == .tv)
        #expect(fetched.matchState == .confirmed)
        #expect(fetched.seasons.first?.episodes.first?.versions.first?.resolution == "1080p")
    }

    @Test("Deleting a Title cascades to seasons/episodes/versions but not shared Tags")
    func deleteCascadesButKeepsTags() throws {
        let ctx = makeContext()

        let tag = IinaMagnet.Tag(name: "奇幻", category: .genre)
        let title = Title(kind: .tv, titleZh: "X", releaseYear: 2020)
        let season = Season(number: 1)
        let ep = Episode(number: 1, seasonNumber: 1)
        ep.versions.append(VersionFile(fileURL: URL(fileURLWithPath: "/tmp/x.mkv"),
                                       fileFingerprint: "1:2002:1",
                                       fileSizeBytes: 1))
        season.episodes.append(ep)
        title.seasons.append(season)
        title.tags.append(tag)
        ctx.insert(title)
        try ctx.save()

        ctx.delete(title)
        try ctx.save()

        #expect(try ctx.fetch(FetchDescriptor<Title>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<Season>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<Episode>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<VersionFile>()).isEmpty)
        // Shared Tag survives (many-to-many, nullify not cascade).
        #expect(try ctx.fetch(FetchDescriptor<IinaMagnet.Tag>()).count == 1)
    }

    @Test("VersionFile.fileFingerprint unique → upsert, no duplicate row")
    func fingerprintUnique() throws {
        let ctx = makeContext()
        let fp = "1:3003:999"
        ctx.insert(VersionFile(fileURL: URL(fileURLWithPath: "/tmp/a.mkv"),
                               fileFingerprint: fp, fileSizeBytes: 1))
        try ctx.save()
        ctx.insert(VersionFile(fileURL: URL(fileURLWithPath: "/tmp/b.mkv"),
                               fileFingerprint: fp, fileSizeBytes: 2))
        try ctx.save()
        #expect(try ctx.fetch(FetchDescriptor<VersionFile>()).count == 1)
    }

    @Test("WatchProgress keys on (title, season, episode), shared across versions")
    func watchProgressKeying() throws {
        let ctx = makeContext()
        let title = Title(kind: .tv, titleZh: "Y", releaseYear: 2021)
        ctx.insert(title)
        let wp = WatchProgress(title: title, seasonNumber: 1, episodeNumber: 3,
                               lastPositionSec: 120, durationSec: 1400, state: .inProgress)
        ctx.insert(wp)
        try ctx.save()

        // Query on value-typed keys (well-supported in #Predicate), then assert
        // the relationship identity in memory.
        let descriptor = FetchDescriptor<WatchProgress>(
            predicate: #Predicate { $0.seasonNumber == 1 && $0.episodeNumber == 3 })
        let found = try ctx.fetch(descriptor)
        #expect(found.count == 1)
        #expect(found.first?.state == .inProgress)
        #expect(found.first?.title?.persistentModelID == title.persistentModelID)
    }

    @Test("Deleting a Title cascade-deletes its WatchProgress (no orphans)")
    func deletingTitleRemovesProgress() throws {
        let ctx = makeContext()
        let title = Title(kind: .tv, titleZh: "Z", releaseYear: 2022)
        ctx.insert(title)
        let wp = WatchProgress(title: title, seasonNumber: 1, episodeNumber: 1,
                               lastPositionSec: 10, durationSec: 100, state: .inProgress)
        ctx.insert(wp)
        try ctx.save()
        #expect(try ctx.fetch(FetchDescriptor<WatchProgress>()).count == 1)

        ctx.delete(title)
        try ctx.save()
        #expect(try ctx.fetch(FetchDescriptor<Title>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<WatchProgress>()).isEmpty)
    }

    @Test("MetadataCache.cacheKey unique → upsert, no duplicate row")
    func metadataCacheUnique() throws {
        let ctx = makeContext()
        let key = "tmdb|12345|zh-Hans"
        ctx.insert(MetadataCache(cacheKey: key, payload: Data([0x1])))
        try ctx.save()
        ctx.insert(MetadataCache(cacheKey: key, payload: Data([0x2])))
        try ctx.save()
        #expect(try ctx.fetch(FetchDescriptor<MetadataCache>()).count == 1)
    }

    @Test("Movie uses placeholder season0/ep0")
    func moviePlaceholder() throws {
        let ctx = makeContext()
        let movie = Title(kind: .movie, titleZh: "电影", releaseYear: 2019,
                          matchState: .confirmed, matchScore: 0.9)
        let s0 = Season(number: 0)
        let e0 = Episode(number: 0, seasonNumber: 0)
        e0.versions.append(VersionFile(fileURL: URL(fileURLWithPath: "/tmp/movie.mkv"),
                                       fileFingerprint: "1:4004:1", fileSizeBytes: 1))
        s0.episodes.append(e0)
        movie.seasons.append(s0)
        ctx.insert(movie)
        try ctx.save()

        let fetched = try #require(try ctx.fetch(FetchDescriptor<Title>()).first)
        #expect(fetched.kind == .movie)
        #expect(fetched.seasons.first?.number == 0)
        #expect(fetched.seasons.first?.episodes.first?.versions.count == 1)
    }

    @Test("Enum raw round-trips through SwiftData")
    func enumRoundTrip() throws {
        let ctx = makeContext()
        let t = Title(kind: .movie, matchState: .pendingConfirmation)
        t.aggregateState = .completed
        ctx.insert(t)
        try ctx.save()
        let fetched = try #require(try ctx.fetch(FetchDescriptor<Title>()).first)
        #expect(fetched.kind == .movie)
        #expect(fetched.matchState == .pendingConfirmation)
        #expect(fetched.aggregateState == .completed)
    }
}

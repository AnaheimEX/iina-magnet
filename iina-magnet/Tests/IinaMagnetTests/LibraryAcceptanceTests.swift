//
//  LibraryAcceptanceTests.swift
//  IinaMagnetTests
//
//  End-to-end acceptance: drive the whole library vertical through the REAL
//  components — scan (LibraryService + FilenameParser + Anitomy) → resolve
//  (MetadataService + SimilarityScorer) → ingest (Ingester) → browse
//  (LibraryItemViewModel + LibraryFilterEngine) → archive (ArchiveViewModel) →
//  watch progress (WatchProgressWriter) → mark-watched → re-bind (LibraryEditor).
//  Only the metadata provider is faked (offline); everything else is production.

import Testing
import Foundation
import SwiftData
@testable import IinaMagnet

@Suite("LibraryAcceptance", .serialized)
struct LibraryAcceptanceTests {

    /// Offline provider: routes a query to canned details by a title substring.
    private struct RoutingProvider: MetadataProvider {
        let id: ProviderID = .bangumi
        let table: [(needle: String, candidate: MetadataCandidate, details: MetadataDetails)]

        func search(_ query: SearchQuery) async throws -> [MetadataCandidate] {
            for row in table where query.title.contains(row.needle) { return [row.candidate] }
            return []
        }
        func details(externalId: String) async throws -> MetadataDetails {
            for row in table where row.candidate.externalId == externalId { return row.details }
            throw MetadataHTTPError.http(status: 404)
        }
    }

    private func provider() -> RoutingProvider {
        let frieren = MetadataDetails(
            providerId: .bangumi, externalId: "459283",
            titleZh: "葬送的芙莉莲", titleJa: "葬送のフリーレン",
            overview: "勇者一行打倒了魔王。", releaseYear: 2023, rating: 8.9,
            episodes: [.init(number: 1, title: "旅程的终点"), .init(number: 2, title: "别来无恙")])
        let spirited = MetadataDetails(
            providerId: .bangumi, externalId: "129",
            titleZh: "千与千寻", titleJa: "千と千尋の神隠し",
            releaseYear: 2001, rating: 9.3, runtimeMinutes: 125)
        return RoutingProvider(table: [
            ("芙莉莲", .init(providerId: .bangumi, externalId: "459283", title: "葬送的芙莉莲", year: 2023), frieren),
            // Candidate display title matches the filename-parsed title (romaji),
            // while details carry the localized name — as the real API returns.
            ("Spirited", .init(providerId: .bangumi, externalId: "129", title: "Spirited Away", year: 2001), spirited),
        ])
    }

    @Test("scan → ingest → browse → archive → watch → mark → re-bind")
    func fullVertical() async throws {
        // Synthetic library: a 2-episode anime, a movie, and an unidentifiable file.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("acpt-" + UUID().uuidString,
                                                                isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let ep1 = root.appendingPathComponent("[喵萌奶茶屋][葬送的芙莉莲][01][1080p].mkv")
        let ep2 = root.appendingPathComponent("[喵萌奶茶屋][葬送的芙莉莲][02][1080p].mkv")
        for url in [ep1, ep2,
                    root.appendingPathComponent("Spirited.Away.2001.1080p.BluRay.mkv"),
                    root.appendingPathComponent("totally_unmatchable_zzz.mkv")] {
            try Data("x".utf8).write(to: url)
        }

        // 1. Scan → resolve → ingest through the real coordinator.
        let ctx = ModelContext(PersistenceController.inMemory().container)
        let coordinator = IngestCoordinator(service: MetadataService(provider: provider()),
                                            context: ModelContextBox(ctx))
        let ingested = try await coordinator.run(roots: [root])
        #expect(ingested == 4)

        let titles = try ctx.fetch(FetchDescriptor<Title>())
        #expect(titles.count == 3)   // anime + movie + one unmatched

        let anime = try #require(titles.first { $0.titleZh == "葬送的芙莉莲" })
        #expect(anime.kind == .tv)
        #expect(anime.matchState == .confirmed)
        #expect(anime.bangumiRating == 8.9)
        #expect(anime.seasons.first?.episodes.count == 2)

        let movie = try #require(titles.first { $0.titleZh == "千与千寻" })
        #expect(movie.kind == .movie)
        #expect(movie.matchState == .confirmed)
        #expect(movie.runtimeMinutes == 125)

        let unmatched = try #require(titles.first { $0.kind == .unknown })
        #expect(unmatched.matchState == .unmatched)

        // 2. Browse: view models + the pure filter engine.
        let items = titles.map(LibraryItemViewModel.init)
        #expect(LibraryFilterEngine.apply(section: .kind(.tv), to: items).count == 1)
        #expect(LibraryFilterEngine.apply(section: .kind(.movie), to: items).count == 1)
        #expect(LibraryFilterEngine.apply(section: .match(.unmatched), to: items).count == 1)
        #expect(LibraryFilterEngine.apply(section: .all, query: "芙莉莲", to: items).count == 1)

        // 3. Archive page projection.
        let archive = ArchiveViewModel(anime)
        #expect(archive.totalEpisodes == 2)
        #expect(archive.ratings.first?.source == .bangumi)

        // 4. Watch progress: play ep1 halfway → 在看; finish both → 已看.
        let writer = WatchProgressWriter(context: ctx)
        _ = try writer.record(url: ep1, positionSec: 50, durationSec: 100, ended: false)
        #expect(TitleDerivations.aggregateState(of: anime) == .inProgress)
        _ = try writer.record(url: ep1, positionSec: 100, durationSec: 100, ended: true)
        _ = try writer.record(url: ep2, positionSec: 100, durationSec: 100, ended: true)
        #expect(anime.aggregateState == .completed)

        // 5. Mark unwatched clears it.
        try writer.setWatched(false, for: anime)
        #expect(anime.aggregateState == .unseen)

        // 6. Re-bind the unmatched file to real metadata.
        let editor = LibraryEditor(context: ctx)
        let rebound = try editor.rebind(unmatched, to: MetadataDetails(
            providerId: .bangumi, externalId: "302835", titleZh: "孤独摇滚", releaseYear: 2022))
        #expect(rebound.titleZh == "孤独摇滚")
        #expect(rebound.matchState == .confirmed)
        #expect(try ctx.fetch(FetchDescriptor<Title>()).count == 3)   // updated in place, no dup
    }
}

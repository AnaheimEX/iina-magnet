//
//  MetadataTests.swift
//  IinaMagnetTests
//
//  MVP metadata chain: BangumiProvider JSON parsing (offline fixtures matching
//  the live API shapes), the single-source candidate picker, and the full
//  scan → resolve → ingest vertical slice into the library models.

import Testing
import Foundation
import SwiftData
@testable import IinaMagnet

// MARK: - Stubs

/// Routes a request to canned JSON by URL substring (offline).
private struct StubClient: MetadataHTTPClient {
    let routes: [(match: String, json: String)]
    func getJSON(_ url: URL) async throws -> Data {
        for r in routes where url.absoluteString.contains(r.match) {
            return Data(r.json.utf8)
        }
        throw MetadataHTTPError.http(status: 404)
    }
}

/// Captures the last requested URL so we can assert how the keyword was encoded.
private final class CapturingClient: MetadataHTTPClient, @unchecked Sendable {
    let json: String
    var lastURL: URL?
    init(json: String) { self.json = json }
    func getJSON(_ url: URL) async throws -> Data { lastURL = url; return Data(json.utf8) }
}

/// Provider returning fixed results without any HTTP — for the e2e test.
private struct FakeProvider: MetadataProvider {
    let id: ProviderID = .bangumi
    let candidate: MetadataCandidate
    let detail: MetadataDetails
    func search(_ query: SearchQuery) async throws -> [MetadataCandidate] { [candidate] }
    func details(externalId: String) async throws -> MetadataDetails { detail }
}

@Suite("Metadata", .serialized)
struct MetadataTests {

    private static let searchJSON = """
    {"results":1,"list":[{"id":459283,"name":"葬送のフリーレン","name_cn":"葬送的芙莉莲",
    "air_date":"2023-10-11","images":{"large":"https://lain.bgm.tv/pic/459283.jpg"}}]}
    """
    private static let subjectJSON = """
    {"name":"葬送のフリーレン","name_cn":"葬送的芙莉莲","summary":"勇者一行打倒了魔王。",
    "date":"2023-10-11","images":{"large":"https://lain.bgm.tv/pic/459283.jpg"},"rating":{"score":6.8}}
    """
    private static let episodesJSON = """
    {"data":[{"ep":1,"sort":1,"name":"魔法のレシピ","name_cn":"","airdate":"2023-10-11"},
    {"ep":2,"sort":2,"name":"jp2","name_cn":"第二集","airdate":"2023-10-25"}]}
    """

    private func bangumiStub() -> BangumiProvider {
        BangumiProvider(client: StubClient(routes: [
            ("/search/subject/", Self.searchJSON),
            ("/v0/subjects/", Self.subjectJSON),
            ("/v0/episodes", Self.episodesJSON),
        ]))
    }

    @Test("BangumiProvider.search maps candidates (name_cn preferred, year from date)")
    func search() async throws {
        let c = try await bangumiStub().search(.init(title: "葬送的芙莉莲", kindHint: .tv))
        #expect(c.count == 1)
        #expect(c.first?.externalId == "459283")
        #expect(c.first?.title == "葬送的芙莉莲")
        #expect(c.first?.year == 2023)
        #expect(c.first?.posterURL?.absoluteString == "https://lain.bgm.tv/pic/459283.jpg")
    }

    @Test("BangumiProvider.details maps titles/overview/rating/episodes")
    func details() async throws {
        let d = try await bangumiStub().details(externalId: "459283")
        #expect(d.titleZh == "葬送的芙莉莲")
        #expect(d.titleJa == "葬送のフリーレン")
        #expect(d.overview == "勇者一行打倒了魔王。")
        #expect(d.releaseYear == 2023)
        #expect(d.rating == 6.8)
        #expect(d.episodes.count == 2)
        #expect(d.episodes.first?.number == 1)
        #expect(d.episodes.first?.title == "魔法のレシピ")   // name_cn empty → falls back to name
        #expect(d.episodes.last?.title == "第二集")          // name_cn present → preferred
    }

    @Test("search percent-encodes '/' in the keyword (Fate/stay night)")
    func slashEncoded() async throws {
        let client = CapturingClient(json: Self.searchJSON)
        _ = try await BangumiProvider(client: client).search(.init(title: "Fate/stay night", kindHint: .tv))
        let s = try #require(client.lastURL?.absoluteString)
        #expect(s.contains("Fate%2Fstay"))
        #expect(!s.contains("Fate/stay"))
    }

    @Test("bestMatch picks the closest title and scores high on exact match")
    func bestMatch() {
        let parsed = ParsedMedia(title: "葬送的芙莉莲", kindHint: .tv)
        let cands = [
            MetadataCandidate(providerId: .bangumi, externalId: "1", title: "别的番"),
            MetadataCandidate(providerId: .bangumi, externalId: "2", title: "葬送的芙莉莲"),
        ]
        let m = MetadataService.bestMatch(parsed, cands)
        #expect(m?.0.externalId == "2")
        #expect((m?.1 ?? 0) >= 0.85)
    }

    @Test("End-to-end: scan → resolve → ingest populates the library")
    func endToEnd() async throws {
        // Synthetic file.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("e2e-" + UUID().uuidString,
                                                                 isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let videoURL = root.appendingPathComponent("[喵萌奶茶屋][葬送的芙莉莲][01][1080p].mkv")
        try Data("x".utf8).write(to: videoURL)
        defer { try? fm.removeItem(at: root) }

        // Scan.
        var scanned: [ScannedFile] = []
        for await p in LibraryService.scan(roots: [root]) {
            if let f = p.file { scanned.append(f) }
        }
        let file = try #require(scanned.first)
        #expect(file.parsed.title == "葬送的芙莉莲")
        #expect(file.parsed.episode == 1)

        // Resolve via a fake provider, then ingest.
        let fake = FakeProvider(
            candidate: .init(providerId: .bangumi, externalId: "459283", title: "葬送的芙莉莲", year: 2023),
            detail: .init(providerId: .bangumi, externalId: "459283",
                          titleZh: "葬送的芙莉莲", titleJa: "葬送のフリーレン",
                          overview: "勇者一行打倒了魔王。",
                          posterURL: URL(string: "https://lain.bgm.tv/pic/459283.jpg"),
                          releaseYear: 2023, rating: 6.8,
                          episodes: [.init(number: 1, title: "魔法のレシピ")]))
        let resolution = await MetadataService(provider: fake).resolve(file.parsed)
        #expect(resolution.state == .confirmed)

        let ctx = ModelContext(PersistenceController.inMemory().container)
        let title = try Ingester(context: ctx).ingest(file, resolution: resolution)
        try ctx.save()

        #expect(title.titleZh == "葬送的芙莉莲")
        #expect(title.titleJa == "葬送のフリーレン")
        #expect(title.bangumiId == 459283)
        #expect(title.kind == .tv)
        #expect(title.matchState == .confirmed)
        #expect(title.posterURL != nil)
        #expect(title.releaseYear == 2023)

        let season = try #require(title.seasons.first)
        #expect(season.number == 1)
        let ep = try #require(season.episodes.first)
        #expect(ep.number == 1)
        #expect(ep.title == "魔法のレシピ")
        let version = try #require(ep.versions.first)
        #expect(version.resolution == "1080p")
        #expect(version.releaseGroup == "喵萌奶茶屋")

        // Auto-tags derived from metadata + version.
        let tagPairs = Set(title.tags.map { "\($0.category.rawValue):\($0.name)" })
        #expect(tagPairs.contains("\(TagCategory.year.rawValue):2023"))
        #expect(tagPairs.contains("\(TagCategory.quality.rawValue):1080p"))
        #expect(tagPairs.contains("\(TagCategory.releaseGroup.rawValue):喵萌奶茶屋"))
        #expect(tagPairs.contains("\(TagCategory.ratingBucket.rawValue):6分+"))   // 6.8
    }

    @Test("IngestCoordinator runs scan→resolve→ingest over a multi-file tree")
    func coordinator() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("coord-" + UUID().uuidString,
                                                                 isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for ep in 1...3 {
            let u = root.appendingPathComponent("[喵萌奶茶屋][葬送的芙莉莲][0\(ep)][1080p].mkv")
            try Data("x".utf8).write(to: u)
        }
        defer { try? fm.removeItem(at: root) }

        let fake = FakeProvider(
            candidate: .init(providerId: .bangumi, externalId: "459283", title: "葬送的芙莉莲", year: 2023),
            detail: .init(providerId: .bangumi, externalId: "459283", titleZh: "葬送的芙莉莲",
                          releaseYear: 2023, rating: 6.8,
                          episodes: (1...3).map { .init(number: $0, title: "第\($0)集") }))
        let ctx = ModelContext(PersistenceController.inMemory().container)
        let coordinator = IngestCoordinator(service: MetadataService(provider: fake),
                                            context: ModelContextBox(ctx))

        var ticks = 0
        let count = try await coordinator.run(roots: [root]) { _ in ticks += 1 }
        #expect(count == 3)
        #expect(ticks >= 3)

        // One Title, one season, three episodes, three version files.
        let titles = try ctx.fetch(FetchDescriptor<Title>())
        #expect(titles.count == 1)
        #expect(titles.first?.seasons.first?.episodes.count == 3)
        #expect(try ctx.fetch(FetchDescriptor<VersionFile>()).count == 3)
    }

    @Test("Ingest is idempotent on fingerprint (re-scan doesn't duplicate)")
    func idempotent() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("idem-" + UUID().uuidString,
                                                                 isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("[G][某番][03][1080p].mkv")
        try Data("x".utf8).write(to: url)
        defer { try? fm.removeItem(at: root) }

        var scanned: [ScannedFile] = []
        for await p in LibraryService.scan(roots: [root]) { if let f = p.file { scanned.append(f) } }
        let file = try #require(scanned.first)

        let ctx = ModelContext(PersistenceController.inMemory().container)
        let ing = Ingester(context: ctx)
        _ = try ing.ingest(file, resolution: nil)
        _ = try ing.ingest(file, resolution: nil)   // re-scan
        #expect(try ctx.fetch(FetchDescriptor<VersionFile>()).count == 1)
    }
}

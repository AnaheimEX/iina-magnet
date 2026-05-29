//
//  BangumiProvider.swift
//  IinaMagnet
//
//  Bangumi.tv metadata source (MVP subset of Issue 07). Uses the official API
//  (anonymous reads, no key) — robust and key-free, ideal for the CJK/anime
//  core scenario. Search uses the legacy GET endpoint (GET-only client);
//  details combine /v0/subjects/{id} + /v0/episodes.

import Foundation

public struct BangumiProvider: MetadataProvider {

    public let id: ProviderID = .bangumi
    private let client: MetadataHTTPClient
    private let host = "https://api.bgm.tv"

    public init(client: MetadataHTTPClient = URLSessionMetadataClient()) {
        self.client = client
    }

    // MARK: search

    public func search(_ query: SearchQuery) async throws -> [MetadataCandidate] {
        // `.urlPathAllowed` keeps "/" — but the keyword sits in a path segment,
        // so titles like "Fate/stay night" must encode it to %2F.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let encoded = query.title.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? query.title
        // type=2 → anime; small response group is enough for candidate display.
        guard let url = URL(string: "\(host)/search/subject/\(encoded)?type=2&responseGroup=small&max_results=10") else {
            return []
        }
        let data = try await client.getJSON(url)
        let resp = try JSONDecoder().decode(SearchResponse.self, from: data)
        return (resp.list ?? []).map { s in
            MetadataCandidate(providerId: .bangumi,
                              externalId: String(s.id),
                              title: s.name_cn?.nonEmpty ?? s.name,
                              year: year(from: s.air_date),
                              posterURL: s.images?.large.flatMap(URL.init(string:)))
        }
    }

    // MARK: details

    public func details(externalId: String) async throws -> MetadataDetails {
        guard let subjectURL = URL(string: "\(host)/v0/subjects/\(externalId)") else {
            throw MetadataHTTPError.transport("bad subject id \(externalId)")
        }
        let subject = try JSONDecoder().decode(Subject.self, from: try await client.getJSON(subjectURL))

        var episodes: [MetadataEpisode] = []
        if let epURL = URL(string: "\(host)/v0/episodes?subject_id=\(externalId)&type=0&limit=100"),
           let epData = try? await client.getJSON(epURL),
           let epResp = try? JSONDecoder().decode(EpisodeResponse.self, from: epData) {
            episodes = epResp.data.map { e in
                MetadataEpisode(number: Int(e.sort ?? Double(e.ep ?? 0)) ,
                                title: e.name_cn?.nonEmpty ?? e.name?.nonEmpty,
                                titleOriginal: e.name?.nonEmpty,
                                overview: nil,
                                airDate: date(from: e.airdate))
            }
        }

        let (genres, countries) = Self.classifyTags(subject.meta_tags ?? [])

        return MetadataDetails(providerId: .bangumi,
                               externalId: externalId,
                               titleZh: subject.name_cn?.nonEmpty,
                               titleJa: subject.name.nonEmpty,
                               titleEn: nil,
                               overview: subject.summary?.nonEmpty,
                               posterURL: subject.images?.large.flatMap(URL.init(string:)),
                               releaseYear: year(from: subject.date),
                               rating: subject.rating?.score,
                               genres: genres,
                               countries: countries,
                               episodes: episodes)
    }

    // MARK: - meta_tags classification

    /// Bangumi's curated `meta_tags` mix genres (奇幻 / 日常 …) with structural
    /// tags (TV / 原创 / 漫画改 …), regions, and years. Route region tokens to
    /// countries, drop structural/numeric noise, keep the rest as genres.
    static func classifyTags(_ metaTags: [String]) -> (genres: [String], countries: [String]) {
        var genres: [String] = []
        var countries: [String] = []
        var seenG = Set<String>(), seenC = Set<String>()

        for raw in metaTags {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if let country = countryTokens[t] {
                if seenC.insert(country).inserted { countries.append(country) }
            } else if structuralTags.contains(t) || t.allSatisfy(\.isNumber) {
                continue   // media type / source / year — not a genre
            } else if seenG.insert(t).inserted {
                genres.append(t)
            }
        }
        return (genres, countries)
    }

    /// Region meta_tags → normalized country name.
    private static let countryTokens: [String: String] = [
        "日本": "日本", "中国": "中国", "中国大陆": "中国", "美国": "美国",
        "韩国": "韩国", "英国": "英国", "法国": "法国",
    ]
    /// Non-genre structural / source / media-type meta_tags to drop.
    private static let structuralTags: Set<String> = [
        "TV", "WEB", "OVA", "OAD", "剧场版", "动画", "番剧", "特摄",
        "原创", "漫画改", "小说改", "游戏改", "Galgame改", "改编",
    ]

    // MARK: - JSON shapes (verified against the live API)

    private struct SearchResponse: Decodable { let list: [SearchItem]? }
    private struct SearchItem: Decodable {
        let id: Int
        let name: String
        let name_cn: String?
        let air_date: String?
        let images: Images?
    }
    private struct Subject: Decodable {
        let name: String
        let name_cn: String?
        let summary: String?
        let date: String?
        let images: Images?
        let rating: Rating?
        let meta_tags: [String]?
    }
    private struct Rating: Decodable { let score: Double? }
    private struct Images: Decodable { let large: String? }
    private struct EpisodeResponse: Decodable { let data: [Ep] }
    private struct Ep: Decodable {
        let ep: Int?
        let sort: Double?
        let name: String?
        let name_cn: String?
        let airdate: String?
    }

    // MARK: - date helpers

    private func year(from s: String?) -> Int? {
        guard let s, s.count >= 4, let y = Int(s.prefix(4)) else { return nil }
        return y
    }

    private func date(from s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return Self.ymd.date(from: s)
    }

    private static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

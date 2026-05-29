//
//  MetadataProvider.swift
//  IinaMagnet
//
//  Phase 2 metadata contract (MVP subset of Issue 05). A provider turns a
//  search query into candidates and a chosen candidate into full details —
//  independent of HOW it fetches (official API or scrape). The MVP wires a
//  single Bangumi provider; the full multi-source merge (ADR-0005) layers on
//  later without changing this protocol.

import Foundation

public enum ProviderID: String, Sendable, Codable {
    case tmdb, bangumi, anilist, douban
}

public struct SearchQuery: Sendable {
    public var title: String
    public var year: Int?
    public var kindHint: MediaKind
    public init(title: String, year: Int? = nil, kindHint: MediaKind) {
        self.title = title
        self.year = year
        self.kindHint = kindHint
    }
}

public struct MetadataCandidate: Sendable, Equatable {
    public var providerId: ProviderID
    public var externalId: String
    public var title: String          // best display title the source gave
    public var year: Int?
    public var posterURL: URL?
    public init(providerId: ProviderID, externalId: String, title: String,
                year: Int? = nil, posterURL: URL? = nil) {
        self.providerId = providerId
        self.externalId = externalId
        self.title = title
        self.year = year
        self.posterURL = posterURL
    }
}

public struct MetadataEpisode: Codable, Sendable, Equatable {
    public var number: Int
    public var title: String?           // localized (zh) title
    public var titleOriginal: String?   // original-language (ja/en) title
    public var overview: String?
    public var airDate: Date?
    public init(number: Int, title: String? = nil, titleOriginal: String? = nil,
                overview: String? = nil, airDate: Date? = nil) {
        self.number = number
        self.title = title
        self.titleOriginal = titleOriginal
        self.overview = overview
        self.airDate = airDate
    }
}

public struct MetadataDetails: Codable, Sendable, Equatable {
    public var providerId: ProviderID
    public var externalId: String
    public var titleZh: String?
    public var titleJa: String?
    public var titleEn: String?
    public var overview: String?
    public var posterURL: URL?
    public var releaseYear: Int?
    public var rating: Double?
    public var runtimeMinutes: Int?
    public var genres: [String]      // 题材标签（奇幻 / 日常 / 治愈…）
    public var countries: [String]   // 制作地区（日本 / 中国…）
    public var episodes: [MetadataEpisode]
    public init(providerId: ProviderID, externalId: String,
                titleZh: String? = nil, titleJa: String? = nil, titleEn: String? = nil,
                overview: String? = nil, posterURL: URL? = nil, releaseYear: Int? = nil,
                rating: Double? = nil, runtimeMinutes: Int? = nil,
                genres: [String] = [], countries: [String] = [],
                episodes: [MetadataEpisode] = []) {
        self.providerId = providerId
        self.externalId = externalId
        self.titleZh = titleZh
        self.titleJa = titleJa
        self.titleEn = titleEn
        self.overview = overview
        self.posterURL = posterURL
        self.releaseYear = releaseYear
        self.rating = rating
        self.runtimeMinutes = runtimeMinutes
        self.genres = genres
        self.countries = countries
        self.episodes = episodes
    }
}

public protocol MetadataProvider: Sendable {
    var id: ProviderID { get }
    func search(_ query: SearchQuery) async throws -> [MetadataCandidate]
    func details(externalId: String) async throws -> MetadataDetails
}

// MARK: - HTTP

public enum MetadataHTTPError: Error, Sendable {
    case http(status: Int)
    case transport(String)
}

/// GET-only JSON transport. Injectable so providers test against fixtures.
public protocol MetadataHTTPClient: Sendable {
    func getJSON(_ url: URL) async throws -> Data
}

public struct URLSessionMetadataClient: MetadataHTTPClient {
    public let userAgent: String
    public let timeoutSeconds: TimeInterval

    public init(userAgent: String = "iina-magnet/0.1 (https://github.com/AnaheimEX/iina-magnet)",
                timeoutSeconds: TimeInterval = 10) {
        self.userAgent = userAgent
        self.timeoutSeconds = timeoutSeconds
    }

    public func getJSON(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")   // Bangumi API etiquette
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw MetadataHTTPError.transport("non-HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw MetadataHTTPError.http(status: http.statusCode)
            }
            return data
        } catch let e as MetadataHTTPError {
            throw e
        } catch {
            throw MetadataHTTPError.transport(error.localizedDescription)
        }
    }
}

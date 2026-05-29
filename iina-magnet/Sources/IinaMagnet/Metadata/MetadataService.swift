//
//  MetadataService.swift
//  IinaMagnet
//
//  MVP single-source resolver (subset of Issue 11). Given a ParsedMedia, search
//  one provider, pick the best candidate by a light title/year score, and fetch
//  details. The full multi-provider concurrency + merge (ADR-0005) replaces the
//  internals later without changing `resolve`.

import Foundation
import OSLog

public struct MetadataResolution: Sendable {
    public let details: MetadataDetails?
    public let candidates: [MetadataCandidate]
    public let score: Double
    public let state: MatchState
}

public actor MetadataService {

    private static let logger = Logger(subsystem: "iina-magnet", category: "metadata")
    private let provider: MetadataProvider

    public init(provider: MetadataProvider) {
        self.provider = provider
    }

    public func resolve(_ parsed: ParsedMedia) async -> MetadataResolution {
        let query = SearchQuery(title: parsed.title, year: parsed.year, kindHint: parsed.kindHint)
        let candidates: [MetadataCandidate]
        do {
            candidates = try await provider.search(query)
        } catch {
            Self.logger.error("\(self.provider.id.rawValue) search failed: \(error.localizedDescription, privacy: .public)")
            return MetadataResolution(details: nil, candidates: [], score: 0, state: .unmatched)
        }
        guard let (best, score) = Self.bestMatch(parsed, candidates) else {
            return MetadataResolution(details: nil, candidates: candidates, score: 0, state: .unmatched)
        }
        let state: MatchState = score >= 0.85 ? .confirmed
            : (score >= 0.65 ? .pendingConfirmation : .unmatched)
        let details = try? await provider.details(externalId: best.externalId)
        return MetadataResolution(details: details, candidates: candidates, score: score, state: state)
    }

    /// Picks the best candidate among one source's results (Issue 09 scorer).
    static func bestMatch(_ parsed: ParsedMedia,
                          _ candidates: [MetadataCandidate]) -> (MetadataCandidate, Double)? {
        SimilarityScorer.bestMatch(parsed, candidates)
    }
}

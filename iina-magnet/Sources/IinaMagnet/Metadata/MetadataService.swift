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

    /// Light scorer (full version is Issue 09): normalized title closeness + a
    /// small year bonus. Good enough to pick among one source's candidates.
    static func bestMatch(_ parsed: ParsedMedia,
                          _ candidates: [MetadataCandidate]) -> (MetadataCandidate, Double)? {
        guard !candidates.isEmpty else { return nil }
        let target = normalize(parsed.title)
        var best: (MetadataCandidate, Double)?
        for c in candidates {
            var s = titleScore(target, normalize(c.title))
            if let py = parsed.year, let cy = c.year {
                s = s * 0.85 + (py == cy ? 0.15 : (abs(py - cy) <= 1 ? 0.07 : 0))
            }
            if best == nil || s > best!.1 { best = (c, s) }
        }
        return best
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "[\\s\\p{P}]+", with: "",
                                            options: .regularExpression)
    }

    /// 0–1 closeness: exact = 1; substring either way scaled by length ratio;
    /// otherwise 0. Cheap, deterministic — no Levenshtein for the MVP.
    private static func titleScore(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        if a.contains(b) || b.contains(a) {
            let short = Double(min(a.count, b.count))
            let long = Double(max(a.count, b.count))
            return 0.6 + 0.4 * (short / long)
        }
        return 0
    }
}

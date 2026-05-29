//
//  TagDeriver.swift
//  IinaMagnet
//
//  Pure deep module (subset of Issue 12): derives auto-tags from a work's
//  metadata + version file. Kept value-only (DerivedTag) so it's free of
//  SwiftData; the Ingester maps these to find-or-created Tag models.
//
//  MVP derives the structured, reliable signals (year / ratingBucket / quality /
//  releaseGroup). genre / country come from clean sources (TMDB) in the
//  multi-source phase; the `genres` parameter is wired but normally empty for now.

import Foundation

public struct DerivedTag: Sendable, Equatable, Hashable {
    public let name: String
    public let category: TagCategory
}

public enum TagDeriver {

    public static func derive(year: Int?,
                              rating: Double?,
                              resolution: String?,
                              releaseGroup: String?,
                              genres: [String] = [],
                              countries: [String] = []) -> [DerivedTag] {
        var tags: [DerivedTag] = []

        for g in genres {
            let name = g.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { tags.append(.init(name: name, category: .genre)) }
        }
        for c in countries {
            let name = c.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { tags.append(.init(name: name, category: .country)) }
        }
        if let year {
            tags.append(.init(name: String(year), category: .year))
        }
        if let bucket = ratingBucket(rating) {
            tags.append(.init(name: bucket, category: .ratingBucket))
        }
        if let resolution, !resolution.isEmpty {
            tags.append(.init(name: resolution, category: .quality))
        }
        if let releaseGroup {
            let name = releaseGroup.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { tags.append(.init(name: name, category: .releaseGroup)) }
        }

        // Dedup while preserving first-seen order.
        var seen = Set<DerivedTag>()
        return tags.filter { seen.insert($0).inserted }
    }

    /// Coarse rating band (0–10 scale). nil for missing/zero ratings.
    static func ratingBucket(_ rating: Double?) -> String? {
        guard let r = rating, r > 0 else { return nil }
        switch r {
        case 9...:      return "9分+"
        case 8..<9:     return "8分+"
        case 7..<8:     return "7分+"
        case 6..<7:     return "6分+"
        default:        return "6分以下"
        }
    }
}

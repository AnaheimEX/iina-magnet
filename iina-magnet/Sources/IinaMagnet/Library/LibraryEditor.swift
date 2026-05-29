//
//  LibraryEditor.swift
//  IinaMagnet
//
//  The metadata fallback / manual-adaptation mechanism behind the archive page's
//  confirm banner (design Archive.jsx). When auto-matching is wrong or absent the
//  user can:
//    • 确认        → confirm the current match            → confirm(_:)
//    • 标为未识别   → drop into the unmatched bucket        → markUnmatched(_:)
//    • 手动修改     → hand-edit core fields                 → applyManual(_:to:)
//    • 重新匹配 /   → re-bind to a metadata record they      → applyRematch(_:to:)
//      手动搜索匹配    picked from a provider search
//
//  All methods are synchronous and mutate the ModelContext, so they run on the
//  context's actor (the main context for UI edits). The async provider search /
//  details fetch is done by the caller and the resulting MetadataDetails is
//  handed to `applyRematch` — keeping the non-Sendable context off the await path
//  (same separation as IngestCoordinator).

import Foundation
import SwiftData
import OSLog

public struct LibraryEditor {

    private static let logger = Logger(subsystem: "iina-magnet", category: "library-editor")
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// 确认：accept the current (auto) match as correct.
    public func confirm(_ title: Title) throws {
        title.matchState = .confirmed
        title.updatedAt = .now
        try context.save()
    }

    /// 标为未识别 / 保留未识别：move the work into the unmatched bucket so it
    /// surfaces in the pending-confirmation queue and the 未识别 filter.
    public func markUnmatched(_ title: Title) throws {
        title.matchState = .unmatched
        title.updatedAt = .now
        try context.save()
    }

    /// 手动修改：override core fields by hand. Only non-empty edits are applied,
    /// and a manual edit is treated as user-confirmed (score 1.0).
    public func applyManual(_ edits: ManualEdits, to title: Title) throws {
        if let v = edits.titleZh?.trimmedNonEmpty { title.titleZh = v }
        if let v = edits.titleJa?.trimmedNonEmpty { title.titleJa = v }
        if let v = edits.titleEn?.trimmedNonEmpty { title.titleEn = v }
        if let v = edits.releaseYear { title.releaseYear = v }
        if let v = edits.kind { title.kind = v }
        if let v = edits.overview?.trimmedNonEmpty { title.overview = v }
        title.matchState = .confirmed
        title.matchScore = 1
        title.updatedAt = .now
        try context.save()
    }

    /// 重新匹配 / 手动搜索匹配：re-bind the work to a metadata record the user
    /// chose. `details` is fetched by the caller off the async provider; here we
    /// apply it to the title + refresh per-episode metadata + tags. The match is
    /// marked confirmed since the user explicitly picked it.
    public func applyRematch(_ details: MetadataDetails, to title: Title) throws {
        MetadataApplier.apply(details, to: title, matchState: .confirmed, matchScore: 1)

        // Refresh per-episode metadata where the new source provides it.
        for season in title.seasons {
            for ep in season.episodes {
                guard let meta = details.episodes.first(where: { $0.number == ep.number }) else { continue }
                ep.title = meta.title ?? ep.title
                ep.titleOriginal = meta.titleOriginal ?? ep.titleOriginal
                ep.overview = meta.overview ?? ep.overview
                ep.airDate = meta.airDate ?? ep.airDate
            }
        }

        // Year / rating tags from the new source. File-derived tags (quality /
        // release group) come from the on-disk files and are unchanged. NOTE:
        // stale year/rating tags from the previous match are not pruned — Tags
        // are shared many-to-many, so safe pruning needs reference counting
        // (follow-up); the new tags are additive here.
        let derived = TagDeriver.derive(year: details.releaseYear, rating: details.rating,
                                        resolution: nil, releaseGroup: nil,
                                        genres: details.genres, countries: details.countries)
        try TagApplier.apply(derived, to: title, context: context)
        CreditApplier.apply(details.cast, to: title, context: context)
        try context.save()
    }
}

/// Hand-entered overrides for a Title; nil fields are left untouched.
public struct ManualEdits: Sendable {
    public var titleZh: String?
    public var titleJa: String?
    public var titleEn: String?
    public var releaseYear: Int?
    public var kind: MediaKind?
    public var overview: String?

    public init(titleZh: String? = nil, titleJa: String? = nil, titleEn: String? = nil,
                releaseYear: Int? = nil, kind: MediaKind? = nil, overview: String? = nil) {
        self.titleZh = titleZh
        self.titleJa = titleJa
        self.titleEn = titleEn
        self.releaseYear = releaseYear
        self.kind = kind
        self.overview = overview
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

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

    /// Removes one work and its catalog-only descendants from SwiftData.
    /// Source media is intentionally untouched; this is not a file deletion.
    public func removeFromLibrary(_ title: Title) throws {
        context.delete(title)
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
        try applyMetadata(details, to: title)
        try context.save()
    }

    /// Re-binds a pending title to the chosen metadata, *merging* it into an
    /// existing Title when one already represents that record (same provider id):
    /// the source's files are migrated onto the existing Title and the now-empty
    /// placeholder is deleted, so a manual confirmation never leaves a duplicate.
    /// Returns the surviving Title. When no existing Title matches, the metadata
    /// is applied to `source` in place (equivalent to `applyRematch`).
    @discardableResult
    public func rebind(_ source: Title, to details: MetadataDetails) throws -> Title {
        if let target = try existingTitle(for: details, excluding: source) {
            migrateFiles(from: source, into: target)
            context.delete(source)
            try applyMetadata(details, to: target)
            try context.save()
            return target
        }
        try applyMetadata(details, to: source)
        try context.save()
        return source
    }

    /// Titles needing attention (not confirmed), newest first — the 待确认队列.
    public func pendingTitles() throws -> [Title] {
        let confirmed = MatchState.confirmed.rawValue
        var d = FetchDescriptor<Title>(predicate: #Predicate { $0.matchStateRaw != confirmed },
                                       sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        d.includePendingChanges = true
        return try context.fetch(d)
    }

    // MARK: - Internals

    /// Copies metadata + episode info + tags + cast onto `title` (no save).
    private func applyMetadata(_ details: MetadataDetails, to title: Title) throws {
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

        // Drop the previous match's source-derived tags before re-deriving, so a
        // re-bind doesn't leave the old year / rating / genre / country behind.
        // File-derived tags (quality / release group from the on-disk files) and
        // user tags are kept — only the metadata-sourced categories are replaced.
        let sourceDerived: Set<TagCategory> = [.year, .ratingBucket, .genre, .country]
        title.tags.removeAll { sourceDerived.contains($0.category) }

        let derived = TagDeriver.derive(year: details.releaseYear, rating: details.rating,
                                        resolution: nil, releaseGroup: nil,
                                        genres: details.genres, countries: details.countries)
        try TagApplier.apply(derived, to: title, context: context)
        CreditApplier.apply(details.cast, to: title, context: context)

        // Episodes/relationships may have changed — keep the tri-state fresh.
        title.aggregateState = TitleDerivations.aggregateState(of: title)
    }

    /// An existing Title (other than `source`) already bound to this record.
    private func existingTitle(for details: MetadataDetails, excluding source: Title) throws -> Title? {
        guard details.providerId == .bangumi, let bid = Int(details.externalId) else { return nil }
        let sid = source.persistentModelID
        var d = FetchDescriptor<Title>(predicate: #Predicate { $0.bangumiId == bid })
        d.includePendingChanges = true
        return try context.fetch(d).first { $0.persistentModelID != sid }
    }

    /// Re-parents every VersionFile (and any WatchProgress) under `source` to the
    /// matching season/episode of `target` (creating those nodes as needed), so
    /// deleting the source placeholder afterwards does not cascade-delete the
    /// files or lose recorded progress.
    private func migrateFiles(from source: Title, into target: Title) {
        for srcSeason in source.seasons {
            let tgtSeason = LibraryTree.season(number: srcSeason.number, in: target)
            for srcEp in srcSeason.episodes {
                let tgtEp = LibraryTree.episode(number: srcEp.number,
                                                seasonNumber: srcSeason.number, in: tgtSeason)
                for version in srcEp.versions {
                    version.episode = tgtEp
                    tgtEp.versions.append(version)
                }
                srcEp.versions.removeAll()
            }
        }

        // Re-key watch progress to the target (kept on (title, season, episode)),
        // skipping any the target already records for the same episode.
        let existingKeys = Set(target.watchProgresses.map { TitleDerivations.EpisodeKey(
            season: $0.seasonNumber ?? -1, episode: $0.episodeNumber ?? -1) })
        for wp in source.watchProgresses {
            let key = TitleDerivations.EpisodeKey(season: wp.seasonNumber ?? -1,
                                                  episode: wp.episodeNumber ?? -1)
            guard !existingKeys.contains(key) else { continue }
            wp.title = target
            target.watchProgresses.append(wp)
        }
        source.watchProgresses.removeAll()
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

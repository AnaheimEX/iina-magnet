//
//  Ingester.swift
//  IinaMagnet
//
//  MVP upsert (subset of Issue 12): folds a ScannedFile + its resolved metadata
//  into Title / Season / Episode / VersionFile. Idempotent on fileFingerprint.
//  Single-source for now (no MetadataMerger yet); metadata is applied directly.

import Foundation
import SwiftData
import OSLog

public struct Ingester {

    private static let logger = Logger(subsystem: "iina-magnet", category: "ingester")
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// Upserts one scanned file. `resolution` may be nil (no metadata found) —
    /// the file still lands in the library under an unmatched/unknown Title so
    /// it stays visible and playable.
    @discardableResult
    public func ingest(_ file: ScannedFile, resolution: MetadataResolution?) throws -> Title {
        // 1. Dedup on fingerprint — update the existing row, don't duplicate.
        let fp = file.fileFingerprint
        if let existing = try fetchVersionFile(fingerprint: fp) {
            existing.fileURL = file.url
            existing.isMissing = false
            try context.save()
            return try existing.episode?.season?.title ?? placeholderTitle(for: file)
        }

        let parsed = file.parsed
        let details = resolution?.details

        // 2. Find or create the Title.
        let title = try findOrCreateTitle(parsed: parsed, details: details)
        apply(details: details, resolution: resolution, to: title, parsed: parsed)
        try applyTags(to: title, details: details, parsed: parsed)

        // 3. Season + Episode (movies use placeholder season0/ep0).
        let isMovie = title.kind == .movie
        let seasonNo = isMovie ? 0 : (parsed.season ?? 1)
        let episodeNo = isMovie ? 0 : (parsed.episode ?? 1)
        let season = season(number: seasonNo, in: title)
        let episode = self.episode(number: episodeNo, seasonNumber: seasonNo, in: season)
        if let meta = details?.episodes.first(where: { $0.number == episodeNo }) {
            episode.title = meta.title ?? episode.title
            episode.titleOriginal = meta.titleOriginal ?? episode.titleOriginal
            episode.overview = meta.overview ?? episode.overview
            episode.airDate = meta.airDate ?? episode.airDate
        }

        // 4. The VersionFile itself.
        let version = VersionFile(fileURL: file.url,
                                  fileFingerprint: fp,
                                  fileSizeBytes: file.sizeBytes,
                                  resolution: parsed.resolution,
                                  releaseGroup: parsed.releaseGroup)
        version.episode = episode
        episode.versions.append(version)
        context.insert(version)

        title.updatedAt = .now
        try context.save()
        return title
    }

    // MARK: - Title

    private func findOrCreateTitle(parsed: ParsedMedia, details: MetadataDetails?) throws -> Title {
        // Prefer matching by Bangumi id when we have metadata.
        if let details, details.providerId == .bangumi, let bid = Int(details.externalId) {
            var d = FetchDescriptor<Title>(predicate: #Predicate { $0.bangumiId == bid })
            d.fetchLimit = 1
            if let found = try context.fetch(d).first { return found }
        }
        // Otherwise match an existing unmatched Title by the parsed title.
        let pt = parsed.title
        var byName = FetchDescriptor<Title>(predicate: #Predicate { $0.titleZh == pt })
        byName.fetchLimit = 1
        if let found = try context.fetch(byName).first { return found }

        let t = Title(kind: parsed.kindHint)
        context.insert(t)
        return t
    }

    private func apply(details: MetadataDetails?, resolution: MetadataResolution?,
                       to title: Title, parsed: ParsedMedia) {
        // kind: trust metadata-backed classification; never downgrade a known kind.
        if title.kind == .unknown { title.kind = parsed.kindHint }

        guard let details else {
            // No metadata: keep a usable title from the parse.
            if title.titleZh == nil { title.titleZh = parsed.title }
            title.matchState = .unmatched
            return
        }
        MetadataApplier.apply(details, to: title,
                              matchState: resolution?.state ?? title.matchState,
                              matchScore: resolution?.score ?? title.matchScore)
        // Parse-derived fallbacks when metadata left a field empty.
        title.titleZh = title.titleZh ?? parsed.title
        title.releaseYear = title.releaseYear ?? parsed.year
    }

    // MARK: - Tags

    private func applyTags(to title: Title, details: MetadataDetails?, parsed: ParsedMedia) throws {
        let derived = TagDeriver.derive(year: details?.releaseYear ?? title.releaseYear ?? parsed.year,
                                        rating: details?.rating,
                                        resolution: parsed.resolution,
                                        releaseGroup: parsed.releaseGroup,
                                        genres: details?.genres ?? [],
                                        countries: details?.countries ?? [])
        try TagApplier.apply(derived, to: title, context: context)
    }

    // MARK: - Season / Episode

    private func season(number: Int, in title: Title) -> Season {
        if let s = title.seasons.first(where: { $0.number == number }) { return s }
        let s = Season(number: number)
        s.title = title
        title.seasons.append(s)
        return s
    }

    private func episode(number: Int, seasonNumber: Int, in season: Season) -> Episode {
        if let e = season.episodes.first(where: { $0.number == number }) { return e }
        let e = Episode(number: number, seasonNumber: seasonNumber)
        e.season = season
        season.episodes.append(e)
        return e
    }

    // MARK: - Lookups

    private func fetchVersionFile(fingerprint: String) throws -> VersionFile? {
        var d = FetchDescriptor<VersionFile>(predicate: #Predicate { $0.fileFingerprint == fingerprint })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    private func placeholderTitle(for file: ScannedFile) throws -> Title {
        let t = Title(kind: file.parsed.kindHint, titleZh: file.parsed.title)
        context.insert(t)
        return t
    }
}

//
//  Title+ViewModel.swift
//  IinaMagnet
//
//  Builds a LibraryItemViewModel from a Title, walking its seasons/episodes/
//  versions and its in-progress WatchProgress. This is the one place that
//  touches SwiftData relationships; the resulting value type is pure + Sendable
//  so the SwiftUI views (and their previews/tests) never hold a model.

import Foundation

extension LibraryItemViewModel {

    public init(_ title: Title) {
        self.id = title.persistentModelID
        self.kind = title.kind
        // A title should always have *some* zh label after ingest; fall back to
        // the best original or a placeholder so the card never renders blank.
        self.titleZh = title.titleZh
            ?? title.titleJa
            ?? title.titleEn
            ?? "未命名"
        self.titleOriginal = title.titleJa ?? title.titleEn
        self.year = title.releaseYear
        self.ratings = LibraryItemViewModel.ratings(of: title)
        self.aggregateState = title.aggregateState
        self.matchState = title.matchState
        self.runtimeMinutes = title.runtimeMinutes
        self.posterURL = title.posterURL
        self.tagNames = title.tags.map(\.name)

        // Walk versions once for count / top quality / file totals.
        let allVersions = title.seasons.flatMap { $0.episodes.flatMap(\.versions) }
        let present = allVersions.filter { !$0.isMissing }
        self.fileCount = present.count
        self.totalSizeBytes = present.reduce(0) { $0 + $1.fileSizeBytes }
        // Design's "版本数": the most versions any single episode/film has.
        self.versionCount = title.seasons
            .flatMap(\.episodes)
            .map(\.versions.count)
            .max() ?? 0
        self.topQuality = LibraryItemViewModel.topQuality(of: present)
        self.rawName = title.kind == .unknown
            ? present.first?.fileURL.lastPathComponent
            : nil

        self.resume = LibraryItemViewModel.resume(of: title)
    }

    // MARK: - Derivations

    private static func ratings(of title: Title) -> [RatingBadge] {
        var out: [RatingBadge] = []
        if let r = title.bangumiRating { out.append(.init(source: .bangumi, value: r)) }
        if let r = title.tmdbRating    { out.append(.init(source: .tmdb,    value: r)) }
        if let r = title.doubanRating  { out.append(.init(source: .douban,  value: r)) }
        return out
    }

    /// Highest available resolution among present files, by pixel height.
    private static func topQuality(of versions: [VersionFile]) -> String? {
        versions
            .compactMap(\.resolution)
            .max { qualityRank($0) < qualityRank($1) }
    }

    /// Orders resolution strings by pixel height ("2160p" > "1080p" > "720p").
    /// The pipeline normalizes to "<height>p", but `resolution` is free-form, so
    /// map the common non-pixel marketing tokens (4K/UHD/2K) rather than ranking
    /// them at 0 (which would sort a 4K file below 1080p).
    private static func qualityRank(_ s: String) -> Int {
        let lower = s.lowercased()
        if lower.contains("4k") || lower.contains("uhd") { return 2160 }
        if lower.contains("2k") { return 1440 }
        let digits = lower.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    private static func resume(of title: Title) -> ResumeInfo? {
        // Most recently touched in-progress episode drives the resume affordance.
        guard let wp = title.watchProgresses
            .filter({ $0.state == .inProgress })
            .max(by: { $0.updatedAt < $1.updatedAt })
        else { return nil }

        return ResumeInfo(
            episodeNumber: wp.episodeNumber.flatMap { $0 > 0 ? $0 : nil },
            label: LibraryFormatting.resumeLabel(episodeNumber: wp.episodeNumber,
                                                 positionSec: wp.lastPositionSec,
                                                 durationSec: wp.durationSec),
            progress: LibraryFormatting.progress(positionSec: wp.lastPositionSec,
                                                 durationSec: wp.durationSec))
    }
}

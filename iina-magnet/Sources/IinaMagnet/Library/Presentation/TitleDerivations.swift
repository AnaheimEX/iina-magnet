//
//  TitleDerivations.swift
//  IinaMagnet
//
//  Shared derivations off a Title, used by both LibraryItemViewModel (browser
//  card) and ArchiveViewModel (detail page) so the two projections agree on
//  ratings ordering, resume affordance, and resolution ranking.

import Foundation

enum TitleDerivations {

    /// Ratings ordered BGM → TMDB → 豆瓣, present-only (ADR-0005 provenance).
    static func ratings(of title: Title) -> [RatingBadge] {
        var out: [RatingBadge] = []
        if let r = title.bangumiRating { out.append(.init(source: .bangumi, value: r)) }
        if let r = title.tmdbRating    { out.append(.init(source: .tmdb,    value: r)) }
        if let r = title.doubanRating  { out.append(.init(source: .douban,  value: r)) }
        return out
    }

    /// Highest available resolution among the given files, by pixel height.
    static func topQuality(of versions: [VersionFile]) -> String? {
        versions
            .compactMap(\.resolution)
            .max { qualityRank($0) < qualityRank($1) }
    }

    /// Orders resolution strings by pixel height ("2160p" > "1080p" > "720p").
    /// The pipeline normalizes to "<height>p", but `resolution` is free-form, so
    /// map the common non-pixel marketing tokens (4K/UHD/2K) rather than ranking
    /// them at 0 (which would sort a 4K file below 1080p).
    static func qualityRank(_ s: String) -> Int {
        let lower = s.lowercased()
        if lower.contains("4k") || lower.contains("uhd") { return 2160 }
        if lower.contains("2k") { return 1440 }
        let digits = lower.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    /// Resume affordance from the most recently touched in-progress episode.
    static func resume(of title: Title) -> ResumeInfo? {
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

    /// Tri-state for the whole work: 全 Episode completed → 已看；有 inProgress /
    /// 部分 completed → 在看；无 → 未看. Pure read; the write paths assign the result
    /// to `title.aggregateState` so the browser filter (Issue 16) stays fresh.
    static func aggregateState(of title: Title) -> ProgressState {
        let episodes = title.seasons.flatMap(\.episodes)
        guard !episodes.isEmpty else { return .unseen }

        let byEpisode = progressByEpisode(of: title)
        var completed = 0, started = 0
        for ep in episodes {
            switch byEpisode[EpisodeKey(season: ep.seasonNumber, episode: ep.number)]?.state {
            case .completed:  completed += 1
            case .inProgress: started += 1
            default:          break
            }
        }
        if completed == episodes.count { return .completed }
        if started > 0 || completed > 0 { return .inProgress }
        return .unseen
    }

    /// Per-episode watch state, keyed (seasonNumber, episodeNumber) — shared
    /// across an episode's versions (PRD US-20).
    static func progressByEpisode(of title: Title) -> [EpisodeKey: WatchProgress] {
        var map: [EpisodeKey: WatchProgress] = [:]
        for wp in title.watchProgresses {
            guard let s = wp.seasonNumber, let e = wp.episodeNumber else { continue }
            map[EpisodeKey(season: s, episode: e)] = wp
        }
        return map
    }

    struct EpisodeKey: Hashable {
        let season: Int
        let episode: Int
    }
}

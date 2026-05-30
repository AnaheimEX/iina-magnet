//
//  WatchProgressWriter.swift
//  IinaMagnet
//
//  Folds a playback sample (url, position, duration, ended) into the library
//  (Issue 17): reverse-looks-up the VersionFile by URL, upserts the WatchProgress
//  keyed on (title, season, episode) — so progress is shared across an episode's
//  versions (PRD US-20) — and recomputes the Title's aggregate tri-state for the
//  browser filter (Issue 16). Synchronous + ModelContext-bound, like Ingester;
//  the actor/debounce live in WatchProgressTracker.

import Foundation
import SwiftData
import OSLog

public struct WatchProgressWriter {

    /// Played fraction at/above which an episode counts as finished.
    public static let completionThreshold = 0.9

    private static let logger = Logger(subsystem: "iina-magnet", category: "watch-progress")
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// Records one playback sample. Returns the affected Title (nil when the URL
    /// isn't a known library file).
    @discardableResult
    public func record(url: URL, positionSec: Double, durationSec: Double,
                       ended: Bool) throws -> Title? {
        guard let version = try versionFile(for: url),
              let episode = version.episode,
              let season = episode.season,
              let title = season.title else { return nil }

        let ratio = durationSec > 0 ? positionSec / durationSec : 0
        let completed = ended || ratio >= Self.completionThreshold

        let progress = findOrCreateProgress(title: title,
                                            season: season.number, episode: episode.number)
        progress.lastPositionSec = positionSec
        progress.durationSec = durationSec
        progress.state = completed ? .completed : .inProgress
        progress.updatedAt = .now

        recomputeAggregate(of: title)
        try context.save()
        return title
    }

    // MARK: - Aggregate tri-state

    /// 全 Episode completed → 已看；有 inProgress/部分 completed → 在看；无 → 未看.
    func recomputeAggregate(of title: Title) {
        let episodes = title.seasons.flatMap(\.episodes)
        guard !episodes.isEmpty else { title.aggregateState = .unseen; return }

        let byEpisode = TitleDerivations.progressByEpisode(of: title)
        var completed = 0, started = 0
        for ep in episodes {
            let key = TitleDerivations.EpisodeKey(season: ep.seasonNumber, episode: ep.number)
            switch byEpisode[key]?.state {
            case .completed:  completed += 1
            case .inProgress: started += 1
            default:          break
            }
        }
        if completed == episodes.count {
            title.aggregateState = .completed
        } else if started > 0 || completed > 0 {
            title.aggregateState = .inProgress
        } else {
            title.aggregateState = .unseen
        }
        title.updatedAt = .now
    }

    // MARK: - Lookups

    private func findOrCreateProgress(title: Title, season: Int, episode: Int) -> WatchProgress {
        if let existing = title.watchProgresses.first(where: {
            $0.seasonNumber == season && $0.episodeNumber == episode
        }) { return existing }
        let wp = WatchProgress(title: title, seasonNumber: season, episodeNumber: episode)
        title.watchProgresses.append(wp)
        context.insert(wp)
        return wp
    }

    /// Reverse lookup by canonical file path — symlinks and `.`/`..`/`~` resolved
    /// on both sides so a file opened via a symlinked path still matches the
    /// stored URL. Keyed on (title, season, episode), so any version of an episode
    /// resolves to the same progress row.
    private func versionFile(for url: URL) throws -> VersionFile? {
        let target = Self.canonicalPath(url)
        let all = try context.fetch(FetchDescriptor<VersionFile>())
        return all.first { Self.canonicalPath($0.fileURL) == target }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

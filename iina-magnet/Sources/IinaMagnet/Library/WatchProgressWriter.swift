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

        title.aggregateState = TitleDerivations.aggregateState(of: title)
        title.updatedAt = .now
        try context.save()
        return title
    }

    // MARK: - Mark watched / unwatched

    /// Marks every episode of a Title watched (or clears all progress), e.g. the
    /// archive page's 标记已看 button. Returns the new aggregate state.
    @discardableResult
    public func setWatched(_ watched: Bool, for title: Title) throws -> ProgressState {
        if watched {
            for season in title.seasons {
                for ep in season.episodes {
                    let wp = findOrCreateProgress(title: title, season: ep.seasonNumber, episode: ep.number)
                    // Completed; keep an end position if we know the duration.
                    if wp.durationSec > 0 { wp.lastPositionSec = wp.durationSec }
                    wp.state = .completed
                    wp.updatedAt = .now
                }
            }
        } else {
            for wp in title.watchProgresses { context.delete(wp) }
            title.watchProgresses.removeAll()
        }
        title.aggregateState = TitleDerivations.aggregateState(of: title)
        title.updatedAt = .now
        try context.save()
        return title.aggregateState
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
        let all = try context.fetch(FetchDescriptor<VersionFile>())
        // Fast path: most plays open the exact stored path (no symlink), so a
        // plain string compare avoids a resolvingSymlinksInPath stat per row.
        let rawPath = url.path
        if let exact = all.first(where: { $0.fileURL.path == rawPath }) {
            return exact
        }
        // Fallback: a symlinked / non-canonical play path resolves both sides.
        let target = Self.canonicalPath(url)
        return all.first { Self.canonicalPath($0.fileURL) == target }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

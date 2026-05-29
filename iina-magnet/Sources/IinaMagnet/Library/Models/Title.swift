//
//  Title.swift
//  IinaMagnet
//
//  A canonical work in the media library (Phase 2, Issue 01). One Title can be
//  a movie or a multi-season TV/anime show. Metadata is merged from multiple
//  providers (ADR-0005); see Issue 10/12 for population.
//
//  Composite indexes (e.g. on `kindRaw`) await the macOS 15 `#Index` macro;
//  the deployment target is macOS 14, so we rely on @Attribute(.unique) for
//  hard constraints and in-memory filtering for the rest. See docs/schema.md.

import Foundation
import SwiftData

@Model
public final class Title {

    // External provider IDs (any subset may be set after merge).
    public var tmdbId: Int?
    public var bangumiId: Int?
    public var anilistId: Int?
    public var doubanId: String?

    // Titles in the three locales we care about (ADR-0005 priority).
    public var titleZh: String?
    public var titleEn: String?
    public var titleJa: String?

    public var kindRaw: Int                  // MediaKind.rawValue
    public var overview: String?
    public var posterURL: URL?
    public var backdropURL: URL?
    public var releaseYear: Int?

    // Ratings kept separately so the UI can show both (ADR-0005).
    public var tmdbRating: Double?
    public var doubanRating: Double?

    public var matchStateRaw: Int            // MatchState.rawValue
    public var matchScore: Double            // similarity score that produced the match

    /// Derived tri-state cache, updated by WatchProgressTracker (Issue 17) and
    /// consumed by the tri-state filter (Issue 16) so the UI never has to walk
    /// every episode. Defaults to .unseen.
    public var aggregateStateRaw: Int

    @Relationship(deleteRule: .cascade, inverse: \Season.title)
    public var seasons: [Season] = []

    // Many-to-many: deleting a Title only drops the association (default nullify),
    // shared Tags persist.
    @Relationship(inverse: \Tag.titles)
    public var tags: [Tag] = []

    // Explicit inverse + cascade so deleting a Title (e.g. re-match cleanup in
    // Issue 18) removes its progress rows instead of orphaning them. WatchProgress
    // is still keyed on (title, season, episode) for cross-version sharing.
    @Relationship(deleteRule: .cascade, inverse: \WatchProgress.title)
    public var watchProgresses: [WatchProgress] = []

    public var createdAt: Date
    public var updatedAt: Date

    public var kind: MediaKind {
        get { MediaKind(rawValue: kindRaw) ?? .unknown }
        set { kindRaw = newValue.rawValue }
    }

    public var matchState: MatchState {
        get { MatchState(rawValue: matchStateRaw) ?? .unmatched }
        set { matchStateRaw = newValue.rawValue }
    }

    public var aggregateState: ProgressState {
        get { ProgressState(rawValue: aggregateStateRaw) ?? .unseen }
        set { aggregateStateRaw = newValue.rawValue }
    }

    public init(kind: MediaKind = .unknown,
                titleZh: String? = nil,
                titleEn: String? = nil,
                titleJa: String? = nil,
                releaseYear: Int? = nil,
                matchState: MatchState = .unmatched,
                matchScore: Double = 0) {
        self.kindRaw = kind.rawValue
        self.titleZh = titleZh
        self.titleEn = titleEn
        self.titleJa = titleJa
        self.releaseYear = releaseYear
        self.matchStateRaw = matchState.rawValue
        self.matchScore = matchScore
        self.aggregateStateRaw = ProgressState.unseen.rawValue
        let now = Date.now
        self.createdAt = now
        self.updatedAt = now
    }
}

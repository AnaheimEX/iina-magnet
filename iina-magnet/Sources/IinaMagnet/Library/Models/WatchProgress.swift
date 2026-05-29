//
//  WatchProgress.swift
//  IinaMagnet
//
//  Per-episode watch state (Phase 2, Issue 01). Written by WatchProgressTracker
//  (Issue 17) from iina playback callbacks.
//
//  Keyed on (title, seasonNumber, episodeNumber) rather than on a VersionFile so
//  that progress is shared across versions of the same episode (PRD US-20).
//  We link to Title via @Relationship instead of storing a PersistentIdentifier
//  directly — SwiftData rejects raw PersistentIdentifier as a stored attribute
//  (same lesson as FeedItem.source).

import Foundation
import SwiftData

@Model
public final class WatchProgress {

    public var title: Title?
    public var seasonNumber: Int?
    public var episodeNumber: Int?

    public var lastPositionSec: TimeInterval
    public var durationSec: TimeInterval
    public var stateRaw: Int            // ProgressState.rawValue
    public var updatedAt: Date

    public var state: ProgressState {
        get { ProgressState(rawValue: stateRaw) ?? .unseen }
        set { stateRaw = newValue.rawValue }
    }

    public init(title: Title?,
                seasonNumber: Int?,
                episodeNumber: Int?,
                lastPositionSec: TimeInterval = 0,
                durationSec: TimeInterval = 0,
                state: ProgressState = .inProgress) {
        self.title = title
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.lastPositionSec = lastPositionSec
        self.durationSec = durationSec
        self.stateRaw = state.rawValue
        self.updatedAt = .now
    }
}

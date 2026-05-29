//
//  LibraryEnums.swift
//  IinaMagnet
//
//  Phase 2 (Issue 01) enums shared by the media-library schema.
//
//  Convention: every enum that is filtered/queried is stored as its raw Int
//  (`*Raw` stored attribute + computed accessor), mirroring TorrentTaskStatus.
//  SwiftData can persist Codable enums (see PollResult), but raw-Int keeps
//  #Predicate filtering on these dimensions straightforward.

import Foundation

/// What kind of work a `Title` is.
public enum MediaKind: Int, Codable, Sendable, CaseIterable {
    case tv      = 0   // 剧集 / 番剧（有季 / 集）
    case movie   = 1   // 电影（占位 season0/ep0）
    case unknown = 2   // 未识别，进待确认队列
}

/// How confident the metadata match is (PRD §IM-7).
public enum MatchState: Int, Codable, Sendable {
    case confirmed           = 0   // score ≥ 0.85，自动入库
    case pendingConfirmation = 1   // 0.65 ≤ score < 0.85，入库但待确认
    case unmatched           = 2   // score < 0.65，进待确认队列
}

/// Category of a `Tag` (ADR-0005 tags; mix of auto-derived and user-defined).
public enum TagCategory: Int, Codable, Sendable {
    case genre        = 0
    case year         = 1
    case country      = 2
    case ratingBucket = 3
    case quality      = 4
    case releaseGroup = 5
    case userDefined  = 6
}

/// Per-episode (and aggregate per-title) watch state, drives the tri-state filter.
public enum ProgressState: Int, Codable, Sendable {
    case unseen     = 0
    case inProgress = 1
    case completed  = 2
}

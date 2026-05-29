//
//  LibraryItemViewModel.swift
//  IinaMagnet
//
//  Presentation layer (Phase 2 UI adaptation): maps the SwiftData models
//  (Title / Season / Episode / VersionFile / WatchProgress) into the flat,
//  display-ready shape the handoff design (`design_handoff_media_library`)
//  expects for poster cards and list rows.
//
//  The design's `Work` object carries several *derived* values — the dual/triple
//  rating badges (ordered BGM → TMDB → 豆瓣), the "续播…" resume label, the
//  version count / top quality, and the file count + total size for unmatched
//  items. Computing them here keeps the SwiftUI views dumb and keeps the logic
//  pure + unit-testable (no SwiftData needed to test the formatting).

import Foundation
import SwiftData

/// A metadata rating with its source, so the UI can badge provenance (ADR-0005).
public struct RatingBadge: Equatable, Sendable {
    public enum Source: String, Sendable, CaseIterable {
        case bangumi, tmdb, douban
        /// Short label shown on the badge.
        public var label: String {
            switch self {
            case .bangumi: return "BGM"
            case .tmdb:    return "TMDB"
            case .douban:  return "豆瓣"
            }
        }
    }
    public let source: Source
    public let value: Double
    public init(source: Source, value: Double) {
        self.source = source
        self.value = value
    }
}

/// A tag name + its category, so the sidebar can group tags (类型 / 地区 / …).
public struct TagRef: Equatable, Hashable, Sendable {
    public let name: String
    public let category: TagCategory
    public init(name: String, category: TagCategory) {
        self.name = name
        self.category = category
    }
}

/// "Continue watching" affordance, present only when a title is in progress.
public struct ResumeInfo: Equatable, Sendable {
    public let episodeNumber: Int?     // nil for movies (whole-film progress)
    public let label: String           // e.g. "续播 第14集 · 还剩 11 分钟"
    public let progress: Double         // 0...1, clamped
    public init(episodeNumber: Int?, label: String, progress: Double) {
        self.episodeNumber = episodeNumber
        self.label = label
        self.progress = progress
    }
}

/// Flattened, display-ready projection of a `Title` for the library browser.
public struct LibraryItemViewModel: Identifiable, Equatable, Sendable {
    public let id: PersistentIdentifier
    public let kind: MediaKind
    public let titleZh: String
    public let titleOriginal: String?  // ja ?? en
    public let year: Int?
    public let ratings: [RatingBadge]  // ordered BGM → TMDB → 豆瓣, present-only
    public let aggregateState: ProgressState
    public let matchState: MatchState
    public let resume: ResumeInfo?
    public let runtimeMinutes: Int?
    public let posterURL: URL?
    public let tags: [TagRef]
    public var tagNames: [String] { tags.map(\.name) }
    public let versionCount: Int       // max versions across episodes (tv) or count (movie)
    public let topQuality: String?     // best available (non-missing) resolution
    public let fileCount: Int          // total version files on disk
    public let totalSizeBytes: Int64
    public let rawName: String?        // original file name, for unmatched items
    public let addedAt: Date           // Title.createdAt, drives 最近添加 sort/section

    /// Highest rating across sources, for the 评分 sort. Zero when unrated.
    public var maxRating: Double { ratings.map(\.value).max() ?? 0 }

    /// Caption shown beneath the poster: unmatched → file summary, else 原名 · 年份.
    public var caption: String {
        if kind == .unknown {
            return fileCount > 0
                ? "\(fileCount) 个文件 · \(LibraryFormatting.size(totalSizeBytes))"
                : "未识别文件"
        }
        return [titleOriginal, year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }
}

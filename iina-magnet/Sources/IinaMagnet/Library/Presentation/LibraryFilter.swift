//
//  LibraryFilter.swift
//  IinaMagnet
//
//  Pure filter + sort engine for the library browser, mirroring the handoff
//  design's App.jsx behaviour: a single-select section (全部 / 最近添加 / 观看状态
//  / 媒体类型 / 待确认), AND-combined tag multi-select, a live text query over
//  title + original + file name, and a sort key. Kept value-only and pure so it
//  is unit-testable without any view or store.

import Foundation

/// The sidebar's single-select section.
public enum LibrarySection: Equatable, Sendable {
    case all
    case recent                  // 最近添加 — newest N by addedAt
    case state(ProgressState)    // 未看 / 在看 / 已看
    case kind(MediaKind)         // 番剧 / 电影 / 未识别
    case match(MatchState)       // 待确认 / 未匹配 entry points
}

/// Toolbar sort options (App.jsx SORTS).
public enum LibrarySort: String, CaseIterable, Sendable {
    case recent, title, year, rating, state

    public var label: String {
        switch self {
        case .recent: return "最近添加"
        case .title:  return "标题"
        case .year:   return "年份"
        case .rating: return "评分"
        case .state:  return "观看状态"
        }
    }
}

public enum LibraryFilterEngine {

    /// Applies section → tags(AND) → query → sort, in that order.
    /// `recentLimit` caps the 最近添加 section.
    public static func apply(section: LibrarySection,
                             tags: [String] = [],
                             query: String = "",
                             sort: LibrarySort = .recent,
                             recentLimit: Int = 12,
                             to items: [LibraryItemViewModel]) -> [LibraryItemViewModel] {
        var list = items

        // 1. Section.
        switch section {
        case .all:
            break
        case .recent:
            list = list.sorted { $0.addedAt > $1.addedAt }.prefix(recentLimit).map { $0 }
        case .state(let s):
            list = list.filter { $0.aggregateState == s }
        case .kind(let k):
            list = list.filter { $0.kind == k }
        case .match(let m):
            list = list.filter { $0.matchState == m }
        }

        // 2. Tags — every selected tag must be present (AND).
        if !tags.isEmpty {
            let wanted = Set(tags)
            list = list.filter { wanted.isSubset(of: Set($0.tagNames)) }
        }

        // 3. Query — case-insensitive over title + original + raw file name.
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { item in
                [item.titleZh, item.titleOriginal, item.rawName]
                    .compactMap { $0?.lowercased() }
                    .contains { $0.contains(q) }
            }
        }

        // 4. Sort. `.recent` keeps the newest-first order from the section step,
        // but re-applies here so the sort menu works under any section.
        switch sort {
        case .recent:
            list.sort { $0.addedAt > $1.addedAt }
        case .title:
            list.sort { $0.titleZh.localizedCompare($1.titleZh) == .orderedAscending }
        case .year:
            list.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        case .rating:
            list.sort { $0.maxRating > $1.maxRating }
        case .state:
            list.sort { stateOrder($0.aggregateState) < stateOrder($1.aggregateState) }
        }
        return list
    }

    /// 在看 → 未看 → 已看, matching the design's state sort.
    private static func stateOrder(_ s: ProgressState) -> Int {
        switch s {
        case .inProgress: return 0
        case .unseen:     return 1
        case .completed:  return 2
        }
    }
}

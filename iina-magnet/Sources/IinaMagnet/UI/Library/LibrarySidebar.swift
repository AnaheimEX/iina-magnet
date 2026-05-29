//
//  LibrarySidebar.swift
//  IinaMagnet
//
//  The floating glass filter sidebar (design Sidebar.jsx): library / 观看状态 /
//  媒体类型 / 待确认 single-select sections with counts, plus collapsible tag
//  groups (multi-select, AND). Counts are derived from the full item set.

import SwiftUI

/// Per-dimension counts shown beside sidebar rows + in the stats bar.
struct LibraryCounts {
    var total = 0
    var byState: [ProgressState: Int] = [:]
    var byKind: [MediaKind: Int] = [:]
    var pending = 0
    var unmatched = 0
    var totalSizeBytes: Int64 = 0

    init(_ items: [LibraryItemViewModel]) {
        total = items.count
        for it in items {
            byState[it.aggregateState, default: 0] += 1
            byKind[it.kind, default: 0] += 1
            if it.matchState == .pendingConfirmation { pending += 1 }
            if it.matchState == .unmatched { unmatched += 1 }
            totalSizeBytes += it.totalSizeBytes
        }
    }
}

private extension TagCategory {
    var groupLabel: String? {
        switch self {
        case .genre:        return "类型"
        case .country:      return "地区"
        case .ratingBucket: return "评分档"
        case .quality:      return "清晰度"
        case .releaseGroup: return "字幕组"
        case .year:         return "年份"
        case .userDefined:  return nil   // shown in a trailing "自定义" group
        }
    }
    var groupIcon: String {
        switch self {
        case .genre: return "tag"
        case .country: return "globe"
        case .ratingBucket: return "star"
        case .quality: return "tv"
        case .releaseGroup: return "captions.bubble"
        case .year: return "calendar"
        case .userDefined: return "tag"
        }
    }
    /// Display order in the sidebar.
    var sortIndex: Int {
        switch self {
        case .genre: return 0
        case .country: return 1
        case .ratingBucket: return 2
        case .quality: return 3
        case .releaseGroup: return 4
        case .year: return 5
        case .userDefined: return 6
        }
    }
}

struct LibrarySidebar: View {
    let items: [LibraryItemViewModel]
    let counts: LibraryCounts            // computed once by the host, shared with the stats bar
    @Binding var section: LibrarySection
    @Binding var selectedTags: Set<String>

    @State private var openGroups: Set<TagCategory> = [.genre]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group {
                    row("全部作品", icon: "books.vertical", count: counts.total,
                        active: section == .all) { section = .all }
                    row("最近添加", icon: "clock", count: nil,
                        active: section == .recent) { section = .recent }
                }

                group(header: "观看状态") {
                    stateRow(.inProgress, "eye")
                    stateRow(.unseen, "eye.slash")
                    stateRow(.completed, "eye.fill")
                }

                group(header: "媒体类型") {
                    kindRow(.tv)
                    kindRow(.movie)
                    kindRow(.unknown)
                }

                if counts.pending > 0 {
                    group {
                        row("待确认匹配", icon: "exclamationmark.triangle.fill",
                            count: counts.pending, active: section == .match(.pendingConfirmation),
                            tint: LibraryTokens.warn) { section = .match(.pendingConfirmation) }
                    }
                }

                tagGroups
            }
            .padding(12)
        }
        .frame(width: LibraryTokens.Spacing.sidebarWidth)
        .background(.ultraThinMaterial)
    }

    // MARK: Builders

    @ViewBuilder
    private func group<Content: View>(header: String? = nil,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let header {
                Text(header).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LibraryTokens.text3)
                    .padding(.horizontal, 8).padding(.bottom, 2)
            }
            content()
        }
    }

    private func stateRow(_ s: ProgressState, _ icon: String) -> some View {
        row(s.displayLabel, icon: icon, count: counts.byState[s] ?? 0,
            active: section == .state(s)) { section = .state(s) }
    }
    private func kindRow(_ k: MediaKind) -> some View {
        row(k.displayLabel, icon: k.glyph, count: counts.byKind[k] ?? 0,
            active: section == .kind(k)) { section = .kind(k) }
    }

    private func row(_ label: String, icon: String, count: Int?, active: Bool,
                     tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13))
                    .frame(width: 18).foregroundStyle(tint ?? LibraryTokens.text2)
                Text(label).font(.system(size: 13))
                    .foregroundStyle(tint ?? LibraryTokens.text)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)").font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(LibraryTokens.text3)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(active ? LibraryTokens.accentSoft : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: Tag groups

    private var tagsByCategory: [(category: TagCategory, names: [String])] {
        var map: [TagCategory: Set<String>] = [:]
        for it in items {
            for t in it.tags { map[t.category, default: []].insert(t.name) }
        }
        return map
            .filter { $0.key.groupLabel != nil && !$0.value.isEmpty }
            .sorted { $0.key.sortIndex < $1.key.sortIndex }
            .map { ($0.key, $0.value.sorted()) }
    }

    @ViewBuilder
    private var tagGroups: some View {
        let groups = tagsByCategory
        if !groups.isEmpty {
            group(header: "标签") {
                ForEach(groups, id: \.category) { g in
                    let open = openGroups.contains(g.category)
                    Button {
                        if open { openGroups.remove(g.category) } else { openGroups.insert(g.category) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").font(.system(size: 10))
                                .foregroundStyle(LibraryTokens.text3)
                                .rotationEffect(.degrees(open ? 90 : 0))
                            Image(systemName: g.category.groupIcon).font(.system(size: 11))
                                .foregroundStyle(LibraryTokens.text3)
                            Text(g.category.groupLabel ?? "").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(LibraryTokens.text)
                            Spacer()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)

                    if open {
                        ForEach(g.names, id: \.self) { name in
                            tagRow(name)
                        }
                    }
                }
            }
        }
    }

    private func tagRow(_ name: String) -> some View {
        let on = selectedTags.contains(name)
        return Button {
            if on { selectedTags.remove(name) } else { selectedTags.insert(name) }
        } label: {
            HStack {
                Text(name).font(.system(size: 12))
                    .foregroundStyle(on ? LibraryTokens.accent : LibraryTokens.text2)
                Spacer()
                if on { Image(systemName: "checkmark").font(.system(size: 10))
                    .foregroundStyle(LibraryTokens.accent) }
            }
            .padding(.leading, 30).padding(.trailing, 8).padding(.vertical, 4)
            .background(on ? LibraryTokens.accentSoft : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// LibrarySection needs Equatable for `section == .state(s)`; the enum already
// derives it. ProgressState/MediaKind/MatchState are Equatable via raw values.

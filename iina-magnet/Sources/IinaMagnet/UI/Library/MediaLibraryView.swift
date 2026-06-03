//
//  MediaLibraryView.swift
//  IinaMagnet
//
//  The media-library browser (design Overview.jsx + App.jsx shell): a glass
//  toolbar, the floating filter sidebar, a poster wall / list, and a bottom
//  stats bar — plus the empty / scanning / error states. The view is driven
//  entirely by an injected `[LibraryItemViewModel]`; filtering/sorting runs
//  through the pure `LibraryFilterEngine`, so this stays presentation-only.

import SwiftUI
import SwiftData

/// What the content area should show, normally `.normal`. The host drives the
/// non-normal states from real library status (configured folders / scan / error).
public enum LibraryDisplayState: Equatable {
    case normal
    case scanning(done: Int, total: Int, current: String)
    case error(title: String, detail: String)
    case unconfigured
    case unscanned(folderSummary: String)
}

enum LibraryViewMode: String { case grid, list }

public struct MediaLibraryView: View {
    private let items: [LibraryItemViewModel]
    private let displayState: LibraryDisplayState
    private let onOpen: (PersistentIdentifier) -> Void
    private let onScan: () -> Void
    private let onCancelScan: () -> Void
    private let onOpenPending: (() -> Void)?
    private let onOpenPikPak: () -> Void
    private let onOpenMikan: () -> Void

    @State private var section: LibrarySection = .all
    @State private var selectedTags: Set<String> = []
    @State private var query: String = ""
    @State private var sort: LibrarySort = .recent
    @State private var viewMode: LibraryViewMode = .grid
    @State private var sidebarOpen = true
    @State private var sidebarCompact = false
    /// Persisted across launches (AppStorage backs CGFloat through Double, the
    /// type it natively supports) so a dragged sidebar width is remembered —
    /// same pattern as PikPakBrowserView's persisted sort choice.
    @AppStorage("library.sidebarWidth") private var sidebarWidthStored: Double
        = Double(LibraryTokens.Spacing.sidebarWidth)
    private var sidebarWidth: Binding<CGFloat> {
        Binding(get: { CGFloat(sidebarWidthStored) }, set: { sidebarWidthStored = Double($0) })
    }

    /// Resize bounds for the (expanded) sidebar; compact mode uses a fixed width.
    private static let sidebarMinWidth: CGFloat = 190
    private static let sidebarMaxWidth: CGFloat = 420

    public init(items: [LibraryItemViewModel],
                displayState: LibraryDisplayState = .normal,
                onOpen: @escaping (PersistentIdentifier) -> Void = { _ in },
                onScan: @escaping () -> Void = {},
                onCancelScan: @escaping () -> Void = {},
                onOpenPending: (() -> Void)? = nil,
                onOpenPikPak: @escaping () -> Void = {},
                onOpenMikan: @escaping () -> Void = {}) {
        self.items = items
        self.displayState = displayState
        self.onOpen = onOpen
        self.onScan = onScan
        self.onCancelScan = onCancelScan
        self.onOpenPending = onOpenPending
        self.onOpenPikPak = onOpenPikPak
        self.onOpenMikan = onOpenMikan
    }

    private var filtered: [LibraryItemViewModel] {
        LibraryFilterEngine.apply(section: section, tags: Array(selectedTags),
                                  query: query, sort: sort, to: items)
    }

    public var body: some View {
        // Compute the filtered list + aggregate counts once per render and thread
        // them through, rather than re-running the pipeline / re-walking `items`
        // in each subview (toolbar count, sidebar, stats bar, content).
        let filtered = self.filtered
        let counts = LibraryCounts(items)
        return VStack(spacing: 0) {
            toolbar(filteredCount: filtered.count)
            Divider().overlay(LibraryTokens.sep)
            HStack(spacing: 0) {
                if sidebarOpen {
                    LibrarySidebar(items: items, counts: counts,
                                   section: $section, selectedTags: $selectedTags,
                                   compact: sidebarCompact,
                                   onOpenPikPak: onOpenPikPak,
                                   onOpenMikan: onOpenMikan)
                        .frame(width: sidebarCompact ? LibrarySidebar.compactWidth : sidebarWidth.wrappedValue)
                    ResizableDivider(width: sidebarWidth,
                                     range: Self.sidebarMinWidth...Self.sidebarMaxWidth,
                                     enabled: !sidebarCompact)
                }
                content(filtered: filtered)
            }
            statsBar(counts)
        }
        .background(LibraryTokens.bg)
    }

    // MARK: Toolbar

    private func toolbar(filteredCount: Int) -> some View {
        HStack(spacing: 10) {
            Button { sidebarOpen.toggle() } label: {
                Image(systemName: "sidebar.left").font(.system(size: 14))
            }.buttonStyle(.plain).foregroundStyle(LibraryTokens.text2)
                .help("显示 / 隐藏侧栏")

            if sidebarOpen {
                Button { withAnimation(.easeInOut(duration: 0.18)) { sidebarCompact.toggle() } } label: {
                    Image(systemName: sidebarCompact
                          ? "arrow.left.and.line.vertical.and.arrow.right"
                          : "arrow.right.and.line.vertical.and.arrow.left")
                        .font(.system(size: 13))
                }.buttonStyle(.plain).foregroundStyle(LibraryTokens.text2)
                    .help(sidebarCompact ? "展开侧栏" : "收紧为图标")
            }

            Text(sectionTitle).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LibraryTokens.text)
            Text("\(filteredCount)").font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(LibraryTokens.text3)

            Spacer()

            Picker("", selection: $viewMode) {
                Image(systemName: "square.grid.2x2").tag(LibraryViewMode.grid)
                Image(systemName: "list.bullet").tag(LibraryViewMode.list)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 84)

            Menu {
                ForEach(LibrarySort.allCases, id: \.self) { s in
                    Button { sort = s } label: {
                        HStack {
                            Text(s.label)
                            if sort == s { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(sort.label).font(.system(size: 12))
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .foregroundStyle(LibraryTokens.text2)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                    .foregroundStyle(LibraryTokens.text3)
                TextField("搜索", text: $query).textFieldStyle(.plain)
                    .font(.system(size: 12)).frame(width: 130)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(LibraryTokens.fill, in: Capsule())

            Button(action: onScan) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise"); Text("扫描").font(.system(size: 12))
                }
            }
            .buttonStyle(.borderedProminent).tint(LibraryTokens.accent)
        }
        .padding(.horizontal, 14)
        .frame(height: LibraryTokens.Spacing.toolbarHeight)
        .background(.ultraThinMaterial)
    }

    // MARK: Content

    @ViewBuilder
    private func content(filtered: [LibraryItemViewModel]) -> some View {
        switch displayState {
        case .scanning(let done, let total, let current):
            VStack(spacing: 0) {
                ScanBanner(done: done, total: total, current: current, onCancel: onCancelScan)
                contentBody(filtered: filtered)
            }
        case .error(let title, let detail):
            VStack(spacing: 0) {
                ErrorBanner(title: title, detail: detail, onRetry: onScan)
                contentBody(filtered: filtered)
            }
        case .unconfigured:
            EmptyStateView(kind: .unconfigured, onAction: onScan)
        case .unscanned(let summary):
            EmptyStateView(kind: .unscanned(summary), onAction: onScan)
        case .normal:
            contentBody(filtered: filtered)
        }
    }

    @ViewBuilder
    private func contentBody(filtered: [LibraryItemViewModel]) -> some View {
        if filtered.isEmpty {
            EmptyStateView(kind: .noResults) {
                section = .all; selectedTags = []; query = ""
            }
        } else if viewMode == .grid {
            gridView(filtered)
        } else {
            listView(filtered)
        }
    }

    private func gridView(_ filtered: [LibraryItemViewModel]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: LibraryTokens.Spacing.wallGap)],
                      spacing: LibraryTokens.Spacing.wallGap) {
                ForEach(filtered) { item in
                    PosterCard(item: item) { onOpen(item.id) }
                }
            }
            .padding(LibraryTokens.Spacing.pagePadding)
        }
    }

    private func listView(_ filtered: [LibraryItemViewModel]) -> some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(filtered) { item in
                    LibraryListRow(item: item) { onOpen(item.id) }
                }
            }
            .padding(.horizontal, LibraryTokens.Spacing.pagePadding)
            .padding(.vertical, 12)
        }
    }

    // MARK: Stats bar

    private func statsBar(_ c: LibraryCounts) -> some View {
        HStack(spacing: 14) {
            stat(MediaKind.tv.displayLabel, c.byKind[.tv] ?? 0) { section = .kind(.tv) }
            stat(MediaKind.movie.displayLabel, c.byKind[.movie] ?? 0) { section = .kind(.movie) }
            stat(MediaKind.unknown.displayLabel, c.byKind[.unknown] ?? 0) { section = .kind(.unknown) }
            if c.pending > 0 {
                stat("待确认", c.pending, tint: LibraryTokens.warn) {
                    // Open the dedicated queue when the host wired it; otherwise
                    // fall back to filtering the grid in place.
                    if let onOpenPending { onOpenPending() }
                    else { section = .match(.pendingConfirmation) }
                }
            }
            Spacer()
            Text("共 \(c.total) 部 · \(LibraryFormatting.size(c.totalSizeBytes))")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(LibraryTokens.text3)
        }
        .padding(.horizontal, 16)
        .frame(height: LibraryTokens.Spacing.statsHeight)
        .background(.ultraThinMaterial)
    }

    private func stat(_ label: String, _ n: Int, tint: Color? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(label) \(n)").font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(tint ?? LibraryTokens.text2)
        }.buttonStyle(.plain)
    }

    private var sectionTitle: String {
        switch section {
        case .all: return "全部作品"
        case .recent: return "最近添加"
        case .state(let s): return s.displayLabel
        case .kind(let k): return k.displayLabel
        case .match(let m): return m == .pendingConfirmation ? "待确认匹配" : m.displayLabel
        }
    }
}

// MARK: - Resizable sidebar divider

/// A 1px separator with a wider invisible hit area that drags the sidebar width
/// within `range`. Shows a left-right resize cursor on hover. When `enabled` is
/// false (compact mode) it's a plain, non-interactive divider.
private struct ResizableDivider: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    var enabled: Bool = true

    @State private var dragBase: CGFloat?

    var body: some View {
        Divider().overlay(LibraryTokens.sep)
            .overlay {
                if enabled {
                    Color.clear
                        .frame(width: 10)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    let base = dragBase ?? width
                                    if dragBase == nil { dragBase = width }
                                    width = min(max(base + v.translation.width, range.lowerBound),
                                                range.upperBound)
                                }
                                .onEnded { _ in dragBase = nil }
                        )
                }
            }
    }
}

// MARK: - Banners + empty states

private struct ScanBanner: View {
    let done: Int, total: Int
    let current: String
    var onCancel: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("正在扫描媒体库… \(done)/\(total)").font(.system(size: 12, weight: .medium))
                Text(current).font(.system(size: 11)).foregroundStyle(LibraryTokens.text3).lineLimit(1)
                ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                    .tint(LibraryTokens.accent)
            }
            Button("取消", action: onCancel).buttonStyle(.bordered).controlSize(.small)
        }
        .padding(12).background(LibraryTokens.accentSoft)
    }
}

private struct ErrorBanner: View {
    let title: String, detail: String
    var onRetry: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LibraryTokens.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(LibraryTokens.text3)
            }
            Spacer()
            Button("重新扫描", action: onRetry).buttonStyle(.bordered).controlSize(.small)
        }
        .padding(12).background(LibraryTokens.warnSoft)
    }
}

private struct EmptyStateView: View {
    enum Kind {
        case unconfigured, unscanned(String), noResults
    }
    let kind: Kind
    var onAction: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(LibraryTokens.text3)
            Text(heading).font(.system(size: 17, weight: .semibold)).foregroundStyle(LibraryTokens.text)
            Text(message).font(.system(size: 13)).foregroundStyle(LibraryTokens.text2)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Button(actionLabel, action: onAction)
                .buttonStyle(.borderedProminent).tint(LibraryTokens.accent).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var icon: String {
        switch kind {
        case .unconfigured: return "books.vertical"
        case .unscanned: return "arrow.clockwise.circle"
        case .noResults: return "magnifyingglass"
        }
    }
    private var heading: String {
        switch kind {
        case .unconfigured: return "媒体库还是空的"
        case .unscanned: return "已添加文件夹，尚未扫描"
        case .noResults: return "没有匹配的作品"
        }
    }
    private var message: String {
        switch kind {
        case .unconfigured: return "添加你的影视文件夹，IINA 会自动刮削番剧与电影的封面、简介与评分。"
        case .unscanned(let s): return s
        case .noResults: return "试着调整筛选条件或清除搜索关键词。"
        }
    }
    private var actionLabel: String {
        switch kind {
        case .unconfigured: return "添加媒体文件夹"
        case .unscanned: return "开始扫描"
        case .noResults: return "清除筛选"
        }
    }
}

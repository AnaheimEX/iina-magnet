//
//  PikPakBrowserView.swift
//  IinaMagnet
//
//  Browses the signed-in PikPak drive: folders drill in (breadcrumb to go
//  back), and tapping a video resolves a fresh direct URL and hands it to iina
//  via IinaBridge — playing the cloud file directly, no download step.

import SwiftUI
import OSLog

/// What to sort the file list by.
enum PikPakSortKey: String, CaseIterable, Sendable {
    case name, modified, size
    var label: String {
        switch self {
        case .name:     return "名称"
        case .modified: return "修改时间"
        case .size:     return "大小"
        }
    }
}

struct PikPakSort: Equatable, Sendable {
    var key: PikPakSortKey
    var ascending: Bool
    static let `default` = PikPakSort(key: .name, ascending: true)
}

/// Pure browsing order: folders always first, then the chosen key (with a
/// natural-name tie-break).
enum PikPakBrowsing {
    static func ordered(_ files: [PikPakFile],
                        by sort: PikPakSort = .default) -> [PikPakFile] {
        files.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let order: ComparisonResult
            switch sort.key {
            case .name:     order = a.name.localizedStandardCompare(b.name)
            case .size:     order = compare(a.size, b.size)
            case .modified: order = compare(a.modifiedTime ?? .distantPast,
                                            b.modifiedTime ?? .distantPast)
            }
            if order != .orderedSame {
                return sort.ascending ? order == .orderedAscending : order == .orderedDescending
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    /// The index to select after moving `delta` rows from `current` within a
    /// list of `count` rows: clamps to the ends, and starts at the first row
    /// when nothing is selected. Returns nil for an empty list.
    static func nextSelectionIndex(count: Int, current: Int?, delta: Int) -> Int? {
        guard count > 0 else { return nil }
        return current.map { min(max($0 + delta, 0), count - 1) } ?? 0
    }

    /// Instant in-folder filter: case- and diacritic-insensitive substring on
    /// the file name. Empty query returns everything unchanged.
    static func filtered(_ files: [PikPakFile], query: String) -> [PikPakFile] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return files }
        return files.filter {
            $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

/// Session-lived cache of folder listings, keyed by folder id, so navigating
/// back into a folder is instant instead of re-fetching from PikPak (which also
/// spares the rate limit). Refresh forces a re-fetch.
final class PikPakListingCache {
    private var byFolder: [String: [PikPakFile]] = [:]

    func entries(for folderID: String) -> [PikPakFile]? { byFolder[folderID] }
    func store(_ files: [PikPakFile], for folderID: String) { byFolder[folderID] = files }
    func invalidate(_ folderID: String) { byFolder[folderID] = nil }
    func invalidateAll() { byFolder.removeAll() }
}

struct PikPakBrowserView: View {
    private static let logger = Logger(subsystem: "iina-magnet", category: "pikpak-browser")

    private struct Folder: Hashable { let id: String; let name: String }
    private enum Phase: Equatable { case loading, loaded, failed(String) }

    @State private var stack: [Folder] = [Folder(id: "", name: "全部文件")]
    @State private var entries: [PikPakFile] = []
    @State private var phase: Phase = .loading
    @State private var openingID: String?
    @State private var openError: String?
    @State private var query = ""
    @State private var cache = PikPakListingCache()
    @State private var selectedID: String?
    @State private var hoverPrefetch: Task<Void, Never>?
    @FocusState private var listFocused: Bool

    // Sort choice is remembered across sessions.
    @AppStorage("pikpak.browser.sortKey") private var sortKeyRaw = PikPakSortKey.name.rawValue
    @AppStorage("pikpak.browser.sortAscending") private var sortAscending = true
    private var sort: PikPakSort {
        PikPakSort(key: PikPakSortKey(rawValue: sortKeyRaw) ?? .name, ascending: sortAscending)
    }

    private var currentID: String { stack.last?.id ?? "" }

    /// What the list actually renders: current folder, filtered by the search
    /// box then ordered by the chosen sort.
    private var visibleEntries: [PikPakFile] {
        PikPakBrowsing.ordered(PikPakBrowsing.filtered(entries, query: query), by: sort)
    }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider().overlay(LibraryTokens.sep)
            content
        }
        // New folder → drop any stale filter/selection, then load (cache makes
        // back-nav instant).
        .task(id: currentID) { query = ""; selectedID = nil; await load() }
    }

    // MARK: Breadcrumb

    private var breadcrumb: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(stack.enumerated()), id: \.element) { index, folder in
                        if index > 0 {
                            Image(systemName: "chevron.right").font(.system(size: 9))
                                .foregroundStyle(LibraryTokens.text3)
                        }
                        Button(folder.name) { stack = Array(stack.prefix(index + 1)) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: index == stack.count - 1 ? .semibold : .regular))
                            .foregroundStyle(index == stack.count - 1 ? LibraryTokens.text : LibraryTokens.text2)
                            .disabled(index == stack.count - 1)
                    }
                }
            }
            Spacer(minLength: 8)
            searchField
            Button { Task { await load(force: true) } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(LibraryTokens.text2).help("刷新")
            sortMenu
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(LibraryTokens.bg2)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 11))
                .foregroundStyle(LibraryTokens.text3)
            TextField("筛选当前文件夹", text: $query)
                .textFieldStyle(.plain).font(.system(size: 12))
                .foregroundStyle(LibraryTokens.text)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(LibraryTokens.text3)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(width: 180)
        .background(LibraryTokens.bg, in: RoundedRectangle(cornerRadius: 6))
    }

    private var sortMenu: some View {
        Menu {
            ForEach(PikPakSortKey.allCases, id: \.self) { key in
                Button {
                    if sort.key == key { sortAscending.toggle() }
                    else { sortKeyRaw = key.rawValue; sortAscending = (key == .name) }
                } label: {
                    HStack {
                        Text(key.label)
                        if sort.key == key {
                            Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 11))
                Text(sort.key.label).font(.system(size: 12))
            }
            .foregroundStyle(LibraryTokens.text2)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            centered { ProgressView().controlSize(.small) }
        case .failed(let message):
            centered {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 30))
                        .foregroundStyle(LibraryTokens.warn)
                    Text(message).font(.system(size: 13)).foregroundStyle(LibraryTokens.text2)
                        .multilineTextAlignment(.center).frame(maxWidth: 360)
                    Button("重试") { Task { await load() } }.controlSize(.small)
                }
            }
        case .loaded where visibleEntries.isEmpty:
            centered {
                VStack(spacing: 8) {
                    Image(systemName: query.isEmpty ? "folder" : "magnifyingglass")
                        .font(.system(size: 30)).foregroundStyle(LibraryTokens.text3)
                    Text(query.isEmpty ? "这个文件夹是空的" : "没有匹配「\(query)」的文件")
                        .font(.system(size: 13)).foregroundStyle(LibraryTokens.text2)
                }
            }
        case .loaded:
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if let openError {
                    Text(openError).font(.system(size: 11)).foregroundStyle(LibraryTokens.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                }
                ForEach(visibleEntries) { file in
                    row(file)
                }
            }
            .padding(.vertical, 8)
        }
        // Keyboard control over the listing: ↑/↓ move the selection, Return /
        // Space open the selected folder or play the selected video.
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow)   { moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1);  return .handled }
        .onKeyPress(.return)    { activateSelected(); return .handled }
        .onKeyPress(.space)     { activateSelected(); return .handled }
        .task { listFocused = true }
    }

    private func row(_ file: PikPakFile) -> some View {
        let playable = !file.isFolder && file.isVideo
        let selected = selectedID == file.id
        return HStack(spacing: 10) {
            Image(systemName: icon(for: file)).font(.system(size: 14))
                .frame(width: 20)
                .foregroundStyle(file.isFolder ? LibraryTokens.accent
                                 : (playable ? LibraryTokens.text : LibraryTokens.text3))
            Text(file.name).font(.system(size: 13)).lineLimit(1)
                .foregroundStyle(file.isFolder || playable ? LibraryTokens.text : LibraryTokens.text3)
            Spacer(minLength: 8)
            if openingID == file.id {
                ProgressView().controlSize(.small)
            } else if !file.isFolder, file.size > 0 {
                Text(LibraryFormatting.size(file.size)).font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(LibraryTokens.text3)
            } else if file.isFolder {
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(LibraryTokens.text3)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(selected ? LibraryTokens.accent.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        // Single click selects (no accidental playback); double click opens the
        // folder / plays the video — the familiar Finder model.
        .onTapGesture(count: 2) { activate(file) }
        .onTapGesture(count: 1) { selectedID = file.id; listFocused = true }
        // Warm the playback URL once the pointer settles on a video row (~300ms
        // debounce), so the click→play handoff skips the detail round-trip
        // without a request per row while the cursor sweeps the list.
        .onHover { hovering in
            guard hovering, playable else { return }
            hoverPrefetch?.cancel()
            hoverPrefetch = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await PikPakDrive.shared.prefetchPlaybackURL(fileID: file.id)
            }
        }
    }

    /// Opens a folder (drill in) or plays a video; no-op for other files.
    private func activate(_ file: PikPakFile) {
        if file.isFolder { stack.append(Folder(id: file.id, name: file.name)) }
        else if file.isVideo { Task { await open(file) } }
    }

    private func activateSelected() {
        guard let id = selectedID, let file = visibleEntries.first(where: { $0.id == id }) else { return }
        activate(file)
    }

    /// Moves the selection by `delta` within the visible list, clamping to the
    /// ends; selects the first row when nothing is selected yet.
    private func moveSelection(_ delta: Int) {
        let items = visibleEntries
        let current = items.firstIndex { $0.id == selectedID }
        guard let next = PikPakBrowsing.nextSelectionIndex(count: items.count,
                                                           current: current, delta: delta) else { return }
        selectedID = items[next].id
    }

    private func icon(for file: PikPakFile) -> String {
        if file.isFolder { return "folder.fill" }
        if file.isVideo { return "play.rectangle.fill" }
        return "doc"
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        inner().frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }

    // MARK: Actions

    @MainActor
    private func load(force: Bool = false) async {
        openError = nil
        // Serve a cached listing instantly (instant back-navigation); `force`
        // (the refresh button) bypasses it.
        if !force, let cached = cache.entries(for: currentID) {
            entries = cached
            phase = .loaded
            return
        }
        phase = .loading
        do {
            let files = try await PikPakDrive.shared.list(parentID: currentID)
            cache.store(files, for: currentID)
            entries = files
            phase = .loaded
        } catch {
            phase = .failed(message(for: error))
            Self.logger.error("list failed: \(self.message(for: error), privacy: .public)")
        }
    }

    @MainActor
    private func open(_ file: PikPakFile) async {
        openingID = file.id
        openError = nil
        defer { openingID = nil }
        do {
            let url = try await PikPakDrive.shared.playbackURL(fileID: file.id)
            guard let bridge = IinaBridgeRegistry.bridge else {
                openError = "无法连接到 IINA 播放器"
                return
            }
            // Logged so the direct-link host can be added to a Surge rule.
            Self.logger.info("pikpak playback host: \(url.host ?? "?", privacy: .public)")
            bridge.openForPlayback(url, options: PlaybackOptions(
                userAgent: PikPakConfig.web.userAgent, enlargeNetworkCache: true))
        } catch {
            openError = "无法播放「\(file.name)」：\(message(for: error))"
        }
    }

    private func message(for error: Error) -> String {
        (error as? PikPakError)?.errorDescription ?? error.localizedDescription
    }
}

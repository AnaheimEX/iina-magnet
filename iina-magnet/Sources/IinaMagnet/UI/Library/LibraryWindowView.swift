//
//  LibraryWindowView.swift
//  IinaMagnet
//
//  Root of the Library window (Issue 20): the @Query host that feeds the
//  browser + detail pages with live data, drives scanning through
//  IngestCoordinator, and wires the archive page's confirm/re-match actions to
//  LibraryEditor + the Bangumi provider. Opened from the Magnet ▸ Library menu.

import SwiftUI
import SwiftData
import AppKit
import OSLog

public struct LibraryWindowView: View {

    private static let logger = Logger(subsystem: "iina-magnet", category: "library-window")

    @Environment(\.modelContext) private var context
    @Query(sort: \Title.createdAt, order: .reverse) private var titles: [Title]

    @State private var route: PersistentIdentifier?          // nil → browser, else archive
    @State private var showPending = false                   // 待确认队列
    @State private var scan: ScanState?
    @State private var didScan = false                       // a scan has completed this session
    @State private var folderStore = LibraryFolderStore.shared

    public init() {}

    private struct ScanState: Equatable {
        var done = 0, total = 0, current = ""
    }

    @State private var itemCache = LibraryItemCache()
    /// Memoized so an unrelated @State change (scan tick, route, sidebar toggle)
    /// doesn't rebuild every card's view model + re-walk every Title's tree.
    private var items: [LibraryItemViewModel] { itemCache.items(for: titles) }

    private var displayState: LibraryDisplayState {
        if let scan { return .scanning(done: scan.done, total: scan.total, current: scan.current) }
        if !folderStore.isConfigured && titles.isEmpty { return .unconfigured }
        // Configured + empty: prompt to scan only if we haven't yet this session;
        // after a scan that found nothing, fall through to the normal (empty) view
        // so the user isn't stuck on the "click to scan" prompt forever.
        if folderStore.isConfigured && titles.isEmpty && !didScan {
            return .unscanned(folderSummary: folderStore.summary())
        }
        return .normal
    }

    public var body: some View {
        Group {
            if let id = route, let title = titles.first(where: { $0.persistentModelID == id }) {
                ArchiveScreen(title: title, onBack: { route = nil },
                              onMergedAway: { route = $0 })
            } else if showPending {
                PendingConfirmationView(
                    items: items.filter { $0.matchState != .confirmed },
                    onBack: { showPending = false },
                    onOpen: { showPending = false; route = $0 },
                    onConfirm: confirm)
            } else {
                MediaLibraryView(items: items,
                                 displayState: displayState,
                                 onOpen: { route = $0 },
                                 onScan: startScan,
                                 onCancelScan: { scan = nil },
                                 onOpenPending: { showPending = true })
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    /// Quick-confirm a pending title from the queue.
    private func confirm(_ id: PersistentIdentifier) {
        guard let title = titles.first(where: { $0.persistentModelID == id }) else { return }
        try? LibraryEditor(context: context).confirm(title)
    }

    // MARK: - Scanning

    private func startScan() {
        if !folderStore.isConfigured, !pickFolders() { return }
        let access = folderStore.resolveRoots()
        guard !access.urls.isEmpty else { access.release(); return }

        scan = ScanState()
        let box = ModelContextBox(ModelContext(context.container))
        let provider = CachingMetadataProvider(BangumiProvider(), cache: .shared)
        let coordinator = IngestCoordinator(
            service: MetadataService(provider: provider),
            context: box)

        Task { @MainActor in
            defer { scan = nil; didScan = true; access.release() }
            do {
                // IngestCoordinator.run is nonisolated async, so its onProgress
                // closure fires off the main actor — hop each tick back to the
                // main actor before touching @State.
                _ = try await coordinator.run(roots: access.urls) { p in
                    let state = ScanState(done: p.scanned, total: p.total,
                                          current: p.current?.lastPathComponent ?? "")
                    Task { @MainActor in scan = state }
                }
            } catch {
                Self.logger.error("scan failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Prompts for media folders; returns true if at least one was added.
    private func pickFolders() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.message = "选择包含番剧 / 电影的文件夹"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return false }
        panel.urls.forEach(folderStore.add)
        return true
    }
}

// MARK: - Archive screen (detail page + edit actions)

/// Wraps ArchiveView with the LibraryEditor actions and the manual-match sheet,
/// so the detail page can confirm / mark-unmatched / hand-edit / re-match.
private struct ArchiveScreen: View {
    let title: Title
    var onBack: () -> Void
    /// Called when a rebind merged this work into a different (existing) Title,
    /// so this archive page now points at a deleted model and must navigate away.
    var onMergedAway: (PersistentIdentifier) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @State private var showMatchSheet = false

    private var editor: LibraryEditor { LibraryEditor(context: context) }
    private var vm: ArchiveViewModel { ArchiveViewModel(title) }

    /// Caching provider (shared store) so a re-match reuses an already-fetched
    /// subject's details and upserts stay serialized on one context.
    private func makeProvider() -> CachingMetadataProvider {
        CachingMetadataProvider(BangumiProvider(), cache: .shared)
    }

    var body: some View {
        ArchiveView(vm: vm,
                    fileInfo: vm.isUnmatched ? vm.fileInfo(from: title) : nil,
                    onBack: onBack,
                    onPlay: { LibraryPlayback.play($0, using: IinaBridgeRegistry.bridge) },
                    onReveal: { LibraryPlayback.revealInFinder($0) },
                    onConfirm: { try? editor.confirm(title) },
                    onMarkUnmatched: { try? editor.markUnmatched(title) },
                    onMatchSheet: { showMatchSheet = true },
                    onToggleWatched: { watched in
                        try? WatchProgressWriter(context: context).setWatched(watched, for: title)
                    })
            .sheet(isPresented: $showMatchSheet) {
                ManualMatchSheet(
                    initialQuery: title.titleZh ?? title.titleJa ?? "",
                    initialEdits: ManualEdits(titleZh: title.titleZh, titleJa: title.titleJa,
                                              releaseYear: title.releaseYear, kind: title.kind),
                    search: { query in
                        let q = SearchQuery(title: query, kindHint: title.kind)
                        return (try? await makeProvider().search(q)) ?? []
                    },
                    onPick: { candidate in
                        showMatchSheet = false
                        rebind(to: candidate)
                    },
                    onManualSave: { edits in
                        showMatchSheet = false
                        try? editor.applyManual(edits, to: title)
                    },
                    onClose: { showMatchSheet = false })
            }
    }

    /// Fetches the picked candidate's full details (async), then re-binds on the
    /// main context — keeping the non-Sendable context off the await path.
    /// `rebind` merges into an existing Title (migrating files) when one already
    /// represents the chosen record, so confirming never leaves a duplicate.
    private func rebind(to candidate: MetadataCandidate) {
        Task { @MainActor in
            guard let details = try? await makeProvider().details(externalId: candidate.externalId)
            else { return }
            guard let survivor = try? editor.rebind(title, to: details) else { return }
            // A merge deleted `title`; this screen now references a dead model —
            // jump to the surviving Title's page.
            if survivor.persistentModelID != title.persistentModelID {
                onMergedAway(survivor.persistentModelID)
            }
        }
    }
}

//
//  BtManagerView.swift
//  IinaMagnet
//
//  SwiftUI window: torrent task table, control buttons, add-by-magnet sheet.
//  Reads TorrentTask via @Query (live updates from TorrentManager's alert pump).

import SwiftUI
import SwiftData

public struct BtManagerView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TorrentTask.addedAt, order: .reverse) private var tasks: [TorrentTask]

    @State private var selectedTaskIds: Set<PersistentIdentifier> = []
    @State private var showAddSheet = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            taskTable
        }
        .sheet(isPresented: $showAddSheet) {
            AddTorrentSheet()
        }
        .navigationTitle("BT Manager")
    }

    private var toolbar: some View {
        HStack {
            Button { showAddSheet = true } label: { Label("Add", systemImage: "plus") }
            Button { pauseSelected() } label: { Label("Pause", systemImage: "pause") }
                .disabled(selectedTaskIds.isEmpty)
            Button { resumeSelected() } label: { Label("Resume", systemImage: "play") }
                .disabled(selectedTaskIds.isEmpty)
            Button(role: .destructive) { removeSelected(deleteFiles: false) } label: {
                Label("Remove", systemImage: "trash")
            }
            .disabled(selectedTaskIds.isEmpty)
            Spacer()
            Text("\(tasks.count) task(s)")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var taskTable: some View {
        Table(tasks, selection: $selectedTaskIds) {
            TableColumn("Name") { task in
                Text(task.displayName).lineLimit(1)
            }
            TableColumn("Status") { task in
                statusChip(for: task.status)
            }.width(110)
            TableColumn("Progress") { task in
                ProgressView(value: task.progress)
            }.width(120)
            TableColumn("Size") { task in
                Text(byteFormatter.string(fromByteCount: task.totalSizeBytes))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }.width(80)
            TableColumn("Updated") { task in
                Text(task.updatedAt.formatted(.relative(presentation: .numeric)))
                    .font(.caption).foregroundStyle(.secondary)
            }.width(120)
        }
        .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
            Button("Pause") { performBatch(ids) { hash in await TorrentManager.shared.pause(hash) } }
            Button("Resume") { performBatch(ids) { hash in await TorrentManager.shared.resume(hash) } }
            Divider()
            Button("Remove (keep files)") { remove(ids: ids, deleteFiles: false) }
            Button("Remove (delete files)", role: .destructive) { remove(ids: ids, deleteFiles: true) }
        } primaryAction: { ids in
            // Double-click: open in iina (Phase 1 plays first file in savePath; Issue 08
            // will hand off to PlayerCore with streaming coordination)
            playFirst(ids: ids)
        }
    }

    // MARK: - Chips

    private func statusChip(for status: TorrentTaskStatus) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .resolving:   return ("Resolving", .blue)
            case .downloading: return ("Downloading", .green)
            case .paused:      return ("Paused", .gray)
            case .seeding:     return ("Seeding", .green)
            case .completed:   return ("Completed", .green)
            case .failed:      return ("Failed", .red)
            case .removed:     return ("Removed", .gray)
            }
        }()
        return Text(label)
            .font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: - Actions

    private func pauseSelected() {
        performBatch(selectedTaskIds) { hash in await TorrentManager.shared.pause(hash) }
    }
    private func resumeSelected() {
        performBatch(selectedTaskIds) { hash in await TorrentManager.shared.resume(hash) }
    }
    private func removeSelected(deleteFiles: Bool) {
        remove(ids: selectedTaskIds, deleteFiles: deleteFiles)
    }

    private func remove(ids: Set<PersistentIdentifier>, deleteFiles: Bool) {
        performBatch(ids) { hash in await TorrentManager.shared.remove(hash, deleteFiles: deleteFiles) }
        selectedTaskIds.removeAll()
    }

    private func performBatch(_ ids: Set<PersistentIdentifier>, _ block: @Sendable @escaping (InfoHash) async -> Void) {
        let hashes = tasks.filter { ids.contains($0.persistentModelID) }.map { InfoHash($0.infoHash) }
        Task {
            for hash in hashes { await block(hash) }
        }
    }

    private func playFirst(ids: Set<PersistentIdentifier>) {
        guard let id = ids.first,
              let task = tasks.first(where: { $0.persistentModelID == id }) else { return }
        // Phase 1 placeholder: just reveal in Finder; Issue 08 wires PlayerCore.
        NSWorkspace.shared.activateFileViewerSelecting([task.savePath])
    }

    private var byteFormatter: ByteCountFormatter {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }
}

// MARK: - Add sheet

private struct AddTorrentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var magnet = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add magnet link").font(.headline)
            TextField("magnet:?xt=urn:btih:…", text: $magnet)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            if let err = error {
                Text(err).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!magnet.lowercased().hasPrefix("magnet:"))
            }
        }
        .padding()
        .frame(width: 560)
    }

    private func add() {
        Task {
            do {
                let save = await MainActor.run { AppSettings.shared.cacheDirectory }
                try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
                _ = try await TorrentManager.shared.addMagnet(magnet, savePath: save)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }
}

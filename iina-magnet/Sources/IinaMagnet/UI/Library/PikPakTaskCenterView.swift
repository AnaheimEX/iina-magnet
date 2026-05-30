//
//  PikPakTaskCenterView.swift
//  IinaMagnet
//
//  PikPak offline-download task center: lists running / pending / failed tasks
//  with progress, and lets the user retry a failed task (re-submits its source
//  URL) or delete it. Saving via Mikan is fire-and-forget, so this is where the
//  user watches a download land and recovers from failures. Auto-refreshes
//  while anything is still in flight.

import SwiftUI
import OSLog

struct PikPakTaskCenterView: View {
    private static let logger = Logger(subsystem: "iina-magnet", category: "pikpak-tasks")

    private enum Phase: Equatable { case loading, loaded, failed(String) }

    @State private var tasks: [PikPakTask] = []
    @State private var phase: Phase = .loading
    @State private var busyID: String?          // a row with a retry/delete in flight
    @State private var actionError: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(LibraryTokens.sep)
            content
        }
        // Re-runs (and cancels) with the view's lifetime: poll while anything
        // is still downloading so progress updates on its own.
        .task { await pollLoop() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("离线任务").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LibraryTokens.text)
            if case .loaded = phase, !tasks.isEmpty {
                Text("\(tasks.count)").font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(LibraryTokens.text3)
            }
            Spacer(minLength: 8)
            Button { Task { await load() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(LibraryTokens.text2)
            .help("刷新")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(LibraryTokens.bg2)
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
        case .loaded where tasks.isEmpty:
            centered {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 30))
                        .foregroundStyle(LibraryTokens.text3)
                    Text("没有进行中的离线任务").font(.system(size: 13)).foregroundStyle(LibraryTokens.text2)
                    Text("在「蜜柑计划」里保存的下载会显示在这里").font(.system(size: 11))
                        .foregroundStyle(LibraryTokens.text3)
                }
            }
        case .loaded:
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if let actionError {
                    Text(actionError).font(.system(size: 11)).foregroundStyle(LibraryTokens.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                }
                ForEach(tasks) { task in row(task) }
            }
            .padding(.vertical, 8)
        }
    }

    private func row(_ task: PikPakTask) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: task)).font(.system(size: 14)).frame(width: 20)
                .foregroundStyle(tint(for: task))
            VStack(alignment: .leading, spacing: 3) {
                Text(task.name.isEmpty ? "未命名任务" : task.name)
                    .font(.system(size: 13)).lineLimit(1).foregroundStyle(LibraryTokens.text)
                subtitle(for: task)
            }
            Spacer(minLength: 8)
            if busyID == task.id {
                ProgressView().controlSize(.small)
            } else {
                actions(for: task)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func subtitle(for task: PikPakTask) -> some View {
        if task.isError {
            Text(task.message?.nonEmpty ?? "下载失败").font(.system(size: 11)).lineLimit(2)
                .foregroundStyle(LibraryTokens.warn)
        } else if task.isRunning || task.isPending {
            HStack(spacing: 8) {
                ProgressView(value: Double(min(max(task.progress, 0), 100)), total: 100)
                    .progressViewStyle(.linear).frame(maxWidth: 220)
                Text(task.isPending ? "等待中" : "\(task.progress)%")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(LibraryTokens.text3)
                if task.fileSize > 0 {
                    Text(LibraryFormatting.size(task.fileSize))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(LibraryTokens.text3)
                }
            }
        } else if task.fileSize > 0 {
            Text(LibraryFormatting.size(task.fileSize))
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(LibraryTokens.text3)
        }
    }

    @ViewBuilder
    private func actions(for task: PikPakTask) -> some View {
        HStack(spacing: 12) {
            if task.isError {
                Button("重试") { Task { await retry(task) } }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(LibraryTokens.accent)
                    .disabled(task.sourceURL?.isEmpty != false)
            } else if !task.fileID.isEmpty {
                Button("云播") { Task { await play(task) } }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(LibraryTokens.accent)
                    .help("内容到达后即可直接播放")
            }
            Button { Task { await delete(task) } } label: {
                Image(systemName: "trash").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(LibraryTokens.text3).help("删除任务")
        }
    }

    private func icon(for task: PikPakTask) -> String {
        if task.isError { return "exclamationmark.triangle.fill" }
        if task.isPending { return "clock" }
        return "arrow.down.circle"
    }

    private func tint(for task: PikPakTask) -> Color {
        task.isError ? LibraryTokens.warn : LibraryTokens.accent
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        inner().frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }

    // MARK: Actions

    /// Polls while any task is still in flight, so progress updates without the
    /// user hitting refresh. Stops once everything is done/errored or the view
    /// goes away (the enclosing `.task` is cancelled).
    @MainActor
    private func pollLoop() async {
        await load()
        while !Task.isCancelled, tasks.contains(where: { $0.isRunning || $0.isPending }) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            await load(silent: true)
        }
    }

    @MainActor
    private func load(silent: Bool = false) async {
        if !silent { phase = .loading }
        do {
            tasks = try await PikPakDrive.shared.tasks()
            phase = .loaded
        } catch {
            if !silent { phase = .failed(message(for: error)) }
            Self.logger.error("tasks load failed: \(self.message(for: error), privacy: .public)")
        }
    }

    @MainActor
    private func retry(_ task: PikPakTask) async {
        busyID = task.id; actionError = nil
        defer { busyID = nil }
        do { _ = try await PikPakDrive.shared.retryTask(task); await load(silent: true) }
        catch { actionError = "重试失败：\(message(for: error))" }
    }

    @MainActor
    private func delete(_ task: PikPakTask) async {
        busyID = task.id; actionError = nil
        defer { busyID = nil }
        do {
            try await PikPakDrive.shared.deleteTask(id: task.id)
            tasks.removeAll { $0.id == task.id }
        } catch { actionError = "删除失败：\(message(for: error))" }
    }

    @MainActor
    private func play(_ task: PikPakTask) async {
        busyID = task.id; actionError = nil
        defer { busyID = nil }
        do {
            let url = try await PikPakDrive.shared.playbackURL(fileID: task.fileID)
            guard let bridge = IinaBridgeRegistry.bridge else {
                actionError = "无法连接到 IINA 播放器"; return
            }
            Self.logger.info("pikpak playback host: \(url.host ?? "?", privacy: .public)")
            bridge.openForPlayback(url, options: PlaybackOptions(
                userAgent: PikPakConfig.web.userAgent, enlargeNetworkCache: true))
        } catch {
            actionError = "暂时无法播放（可能仍在下载）：\(message(for: error))"
        }
    }

    private func message(for error: Error) -> String {
        (error as? PikPakError)?.errorDescription ?? error.localizedDescription
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

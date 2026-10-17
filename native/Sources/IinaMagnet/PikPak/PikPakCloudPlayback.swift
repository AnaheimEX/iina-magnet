import Foundation
import Combine

/// Owns the local save-and-play intent; cancelling never deletes a cloud task.
@MainActor
final class PikPakCloudPlayback: ObservableObject {
    enum Phase: Equatable { case idle, saving, waiting, choosing, opening, finished, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var message = ""
    @Published private(set) var files: [PikPakFile] = []
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private var session: UInt64 = 0
    private var folders: [String] = []

    var busy: Bool { phase == .saving || phase == .waiting || phase == .opening }
    var canGoBack: Bool { folders.count > 1 }

    func cancel() {
        operationID = UUID()
        operation?.cancel()
        operation = nil
        phase = .idle
        files = []
        folders = []
        message = ""
    }

    func start(url: String, name: String, play: Bool) {
        cancel()
        let id = operationID
        phase = .saving
        message = "正在保存到 PikPak…"
        operation = Task {
            do {
                let generation = try await PikPakAuth.shared.prepareRequestSession()
                try Task.checkCancellation()
                guard id == operationID else { throw CancellationError() }
                session = generation
                guard await PikPakAuth.shared.isSignedIn else { throw PikPakError.notAuthenticated }
                try await check(id)
                let task = try await PikPakDrive.shared.offlineDownload(
                    url: url, name: name, waitForFolderMove: !play)
                try await check(id)
                if play {
                    try await resolve(fileID: task.fileID, task: task, id: id)
                } else {
                    phase = .finished
                    message = "已添加到 PikPak 离线下载，完成后可在网盘播放"
                }
            } catch { finish(error, id: id) }
        }
    }

    func select(_ file: PikPakFile) { load(fileID: file.id) }

    func goBack() {
        guard canGoBack else { return }
        folders.removeLast()
        load(fileID: folders.last!)
    }

    private func load(fileID: String) {
        operation?.cancel()
        operationID = UUID()
        let id = operationID
        phase = .waiting
        operation = Task {
            do { try await resolve(fileID: fileID, task: nil, id: id) }
            catch { finish(error, id: id) }
        }
    }

    private enum Resolution: Sendable {
        case url(URL)
        case folder(String, [PikPakFile])
    }

    private func resolve(fileID: String, task: PikPakTask?, id: UUID) async throws {
        phase = .waiting
        message = "已保存，正在等待云端文件就绪…"
        let result = try await withThrowingTaskGroup(of: Resolution.self) { group in
            group.addTask { try await self.poll(fileID: fileID, task: task, id: id) }
            group.addTask {
                try await Task.sleep(nanoseconds: 90_000_000_000)
                throw PikPakError.api(code: -7, message: "文件仍未就绪；云端任务会继续，可稍后从网盘播放")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        try await check(id)
        switch result {
        case .folder(let folderID, let children):
            if folders.last != folderID { folders.append(folderID) }
            files = children
            phase = .choosing
            message = children.isEmpty ? "此目录没有可播放视频" : "选择要播放的视频或文件夹"
        case .url(let url):
            guard let bridge = IinaBridgeRegistry.bridge else {
                throw PikPakError.api(code: -8, message: "IINA 播放器尚未连接")
            }
            phase = .opening
            message = "正在加载视频…"
            try await bridge.openForPlaybackAndWait(url, options: PlaybackOptions(
                userAgent: PikPakConfig.web.userAgent, enlargeNetworkCache: true))
            try await check(id)
            phase = .finished
            message = "IINA 已加载视频"
        }
    }

    private func poll(fileID initialID: String, task initialTask: PikPakTask?, id: UUID) async throws -> Resolution {
        var fileID = initialID
        var task = initialTask
        // Try the returned file immediately; listing task pages must not delay
        // the common case where a cached torrent is already playable.
        var nextTaskCheck = initialID.isEmpty ? Date.distantPast : Date().addingTimeInterval(6)
        var failures = 0
        var attempts = 0
        if initialTask?.isError == true {
            throw PikPakError.api(code: -8, message: initialTask?.message ?? "PikPak 离线任务失败")
        }
        while true {
            try await check(id)
            do {
                if let current = task, Date() >= nextTaskCheck {
                    task = try await PikPakDrive.shared.task(id: current.id) ?? current
                    try await check(id)
                    nextTaskCheck = Date().addingTimeInterval(6)
                    if let latest = task {
                        if latest.isError {
                            throw PikPakError.api(code: -8, message: latest.message ?? "PikPak 离线任务失败")
                        }
                        if !latest.fileID.isEmpty { fileID = latest.fileID }
                        message = "正在等待云端文件就绪（\(latest.progress)%）…"
                    }
                }
                if !fileID.isEmpty {
                    let details = try await PikPakDrive.shared.fileDetails(fileID: fileID)
                    try await check(id)
                    if details.file.isFolder {
                        let children = try await PikPakDrive.shared.list(parentID: fileID, onlyCompleted: false)
                        try await check(id)
                        let playable = children.filter { $0.isFolder || $0.isVideo }
                        if !playable.isEmpty || task == nil || task?.isComplete == true {
                            return .folder(fileID, playable)
                        }
                    } else if let url = details.playbackURL {
                        return .url(url)
                    }
                }
                failures = 0
            } catch {
                try await check(id)
                if Self.notReady(error) {
                    failures = 0
                } else if Self.transient(error), failures < 2 {
                    failures += 1
                } else { throw error }
            }
            // Cached torrents often become visible just after task creation.
            // Probe sooner initially, then back off instead of polling fast
            // throughout a long server-side download.
            let delay = failures > 0 ? 2.0 : min(2.0, 0.35 * pow(2.0, Double(min(attempts, 3))))
            attempts += 1
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func check(_ id: UUID) async throws {
        try Task.checkCancellation()
        guard id == operationID else { throw CancellationError() }
        guard await PikPakAuth.shared.sessionGeneration == session else {
            throw PikPakError.notAuthenticated
        }
        try Task.checkCancellation()
    }

    private func finish(_ error: Error, id: UUID) {
        guard id == operationID else { return }
        phase = .failed
        message = error is CancellationError ? "操作已取消" : error.localizedDescription
    }

    private static func notReady(_ error: Error) -> Bool {
        switch error {
        case PikPakError.api(let code, _): return code == 404 || code == -1
        case PikPakError.http(let status): return status == 404
        default: return false
        }
    }

    private static func transient(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                    .dnsLookupFailed, .notConnectedToInternet].contains(error.code)
        }
        switch error {
        case PikPakError.http(let code), PikPakError.api(let code, _):
            return [408, 429, 500, 502, 503, 504].contains(code)
        default: return false
        }
    }
}

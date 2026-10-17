//
//  PikPakDrive.swift
//  IinaMagnet
//
//  PikPak drive API: list folders/files and resolve a playable direct URL for a
//  video, using the session from PikPakAuth. Mirrors the alist/OpenList driver:
//  GET api-drive.mypikpak.net/drive/v1/files with Bearer auth; on PikPak's error
//  codes it refreshes the access token (16 / 4121 / 4122) or re-signs a captcha
//  token (9) and retries.

import Foundation
import OSLog

// MARK: - Public model

public struct PikPakFile: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let isFolder: Bool
    public let size: Int64
    public let mimeType: String?
    public let thumbnailURL: URL?
    public let modifiedTime: Date?

    public init(id: String, name: String, isFolder: Bool, size: Int64,
                mimeType: String?, thumbnailURL: URL?, modifiedTime: Date?) {
        self.id = id
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.mimeType = mimeType
        self.thumbnailURL = thumbnailURL
        self.modifiedTime = modifiedTime
    }

    /// Whether this file looks like a playable video (by MIME, else extension).
    public var isVideo: Bool {
        if let mimeType, mimeType.hasPrefix("video/") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return Self.videoExtensions.contains(ext)
    }

    static let videoExtensions: Set<String> = [
        "mp4", "mkv", "mov", "avi", "wmv", "flv", "webm", "m4v", "mpg", "mpeg",
        "ts", "m2ts", "rmvb", "rm", "3gp", "vob", "ogv", "f4v",
    ]
}

/// A PikPak offline-download task.
public struct PikPakTask: Sendable, Equatable, Identifiable {
    public let id: String
    public let fileID: String
    public let name: String
    public let phase: String        // PHASE_TYPE_RUNNING / _COMPLETE / _PENDING / _ERROR
    public let progress: Int        // 0...100
    public let fileSize: Int64
    public let message: String?     // failure / status detail, when any
    public let sourceURL: String?   // original magnet / URL, used to retry
    public let createdTime: Date?

    public init(id: String, fileID: String, name: String, phase: String,
                progress: Int = 0, fileSize: Int64 = 0, message: String? = nil,
                sourceURL: String? = nil, createdTime: Date? = nil) {
        self.id = id
        self.fileID = fileID
        self.name = name
        self.phase = phase
        self.progress = progress
        self.fileSize = fileSize
        self.message = message
        self.sourceURL = sourceURL
        self.createdTime = createdTime
    }

    public var isComplete: Bool { phase == "PHASE_TYPE_COMPLETE" }
    public var isRunning: Bool  { phase == "PHASE_TYPE_RUNNING" }
    public var isPending: Bool  { phase == "PHASE_TYPE_PENDING" }
    public var isError: Bool    { phase == "PHASE_TYPE_ERROR" }
}

// MARK: - Drive client

private enum PikPakDriveOperation {
    @TaskLocal static var sessionGeneration: UInt64?
}

public actor PikPakDrive {
    public static let shared = PikPakDrive()
    private static let logger = Logger(subsystem: "iina-magnet", category: "pikpak-drive")

    private let auth: PikPakAuth
    private let http: PikPakHTTPClient
    private let config: PikPakConfig
    private var cacheSessionGeneration: UInt64?
    private var sessionObserver: NSObjectProtocol?

    /// Cloud folder offline downloads are saved into; created on first use.
    public var offlineFolderName = "Pack From Shared"
    private var cachedOfflineFolderID: String?
    private var folderPreparation: (id: UUID, task: Task<Void, Never>)?

    /// Short-lived cache of resolved playback URLs, keyed by file id. Warmed by
    /// `prefetchPlaybackURL` (on row hover) so the click→play path can skip the
    /// detail round-trip. PikPak's signed links stay valid well beyond this TTL.
    private var playbackURLCache: [String: (url: URL, fetchedAt: Date)] = [:]
    private let playbackURLTTL: TimeInterval = 5 * 60
    private struct PlaybackURLRequest {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<URL, Error>]
    }
    /// Prefetch, playback and polling share a request, with independent cancellation.
    private var playbackURLRequests: [String: PlaybackURLRequest] = [:]

    public init(auth: PikPakAuth = .shared,
                http: PikPakHTTPClient = URLSessionPikPakClient(),
                config: PikPakConfig = .web) {
        self.auth = auth
        self.http = http
        self.config = config
    }

    deinit {
        if let sessionObserver { NotificationCenter.default.removeObserver(sessionObserver) }
    }

    /// Nested calls and unstructured playback/move tasks inherit the same
    /// account lifetime, so retries cannot silently switch to a new login.
    private func withSession<T>(_ operation: () async throws -> T) async throws -> T {
        if sessionObserver == nil {
            sessionObserver = NotificationCenter.default.addObserver(
                forName: PikPakAuth.sessionDidChangeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                Task { await self?.sessionDidChange() }
            }
        }
        let generation: UInt64
        if let inherited = PikPakDriveOperation.sessionGeneration {
            generation = inherited
        } else {
            generation = try await auth.prepareRequestSession()
        }
        try await checkSession(generation)
        return try await PikPakDriveOperation.$sessionGeneration.withValue(generation) {
            do {
                let value = try await operation()
                try await self.checkSession(generation)
                return value
            } catch {
                try Task.checkCancellation()
                // A rejected refresh clears the session and advances its generation.
                // Preserve that auth failure unless another login has replaced it.
                if error as? PikPakError == .notAuthenticated,
                   !(await self.auth.isSignedIn) {
                    throw error
                }
                // An old account's auth failure must not sign out the new one.
                try await self.checkSession(generation)
                throw error
            }
        }
    }

    private func sessionDidChange() async {
        synchronizeCaches(generation: await auth.sessionGeneration)
    }

    private func checkSession(_ expected: UInt64) async throws {
        try Task.checkCancellation()
        let current = await auth.sessionGeneration
        synchronizeCaches(generation: current)
        guard current == expected, cacheSessionGeneration == expected else {
            throw CancellationError()
        }
    }

    private func synchronizeCaches(generation: UInt64) {
        if let cached = cacheSessionGeneration, cached >= generation { return }
        cacheSessionGeneration = generation
        cachedOfflineFolderID = nil
        playbackURLCache.removeAll()
        let pending = playbackURLRequests.values
        playbackURLRequests.removeAll()
        for request in pending {
            request.task.cancel()
            for waiter in request.waiters.values {
                waiter.resume(throwing: CancellationError())
            }
        }
    }

    /// Lists a folder's children (parentID "" = root), following pagination.
    /// `onlyCompleted` (default) hides in-progress downloads from the browser;
    /// folder lookups pass `false` so an existing folder is always found
    /// (avoiding spurious duplicate folders).
    public func list(parentID: String = "", onlyCompleted: Bool = true) async throws -> [PikPakFile] {
        try await withSession { try await self.listInSession(parentID: parentID, onlyCompleted: onlyCompleted) }
    }

    private func listInSession(parentID: String = "", onlyCompleted: Bool = true) async throws -> [PikPakFile] {
        var files: [PikPakFile] = []
        var pageToken: String? = ""           // "" → first page
        repeat {
            let resp = try await listPage(parentID: parentID, onlyCompleted: onlyCompleted,
                                          pageToken: pageToken ?? "")
            files.append(contentsOf: (resp.files ?? []).map(\.asPikPakFile))
            let next = resp.next_page_token
            pageToken = (next?.isEmpty == false) ? next : nil
        } while pageToken != nil
        return files
    }

    private func listPage(parentID: String, onlyCompleted: Bool,
                          pageToken: String) async throws -> PPFilesResponse {
        let filter = onlyCompleted
            ? #"{"phase":{"eq":"PHASE_TYPE_COMPLETE"},"trashed":{"eq":false}}"#
            : #"{"trashed":{"eq":false}}"#
        let data = try await authorizedGet(path: "/drive/v1/files", query: [
            "parent_id": parentID,
            "thumbnail_size": "SIZE_LARGE",
            "with_audit": "true",
            "limit": "100",
            "filters": filter,
            "page_token": pageToken,
        ])
        return try decode(PPFilesResponse.self, from: data)
    }

    private func fetchFile(_ fileID: String) async throws -> PPFile {
        let data = try await authorizedGet(path: "/drive/v1/files/\(fileID)", query: [:])
        return try decode(PPFile.self, from: data)
    }

    public func fileDetails(fileID: String) async throws -> (file: PikPakFile, playbackURL: URL?) {
        try await withSession {
            let file = try await self.fetchFile(fileID)
            return (file.asPikPakFile, file.bestPlaybackURL)
        }
    }

    /// A directly playable URL for a video file. Served from the short-lived
    /// cache when warm (so click→play is instant); otherwise fetches the file
    /// detail and caches the resolved link. Pass `allowCached: false` to force a
    /// fresh fetch.
    public func playbackURL(fileID: String, allowCached: Bool = true) async throws -> URL {
        try await withSession { try await self.playbackURLInSession(fileID: fileID, allowCached: allowCached) }
    }

    private func playbackURLInSession(fileID: String, allowCached: Bool = true) async throws -> URL {
        try Task.checkCancellation()
        if allowCached, let hit = playbackURLCache[fileID],
           Date().timeIntervalSince(hit.fetchedAt) < playbackURLTTL {
            return hit.url
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if playbackURLRequests[fileID] != nil {
                    playbackURLRequests[fileID]?.waiters[waiterID] = continuation
                    return
                }
                let requestID = UUID()
                let task = Task {
                    let result: Result<URL, Error>
                    do {
                        let file = try await fetchFile(fileID)
                        try Task.checkCancellation()
                        guard let url = file.bestPlaybackURL else {
                            throw PikPakError.api(code: -1, message: "该文件没有可播放的链接")
                        }
                        result = .success(url)
                    } catch {
                        result = .failure(error)
                    }
                    finishPlaybackURLRequest(fileID: fileID, requestID: requestID, result: result)
                }
                playbackURLRequests[fileID] = PlaybackURLRequest(
                    id: requestID, task: task, waiters: [waiterID: continuation])
            }
        } onCancel: {
            Task { await self.cancelPlaybackURLWaiter(fileID: fileID, waiterID: waiterID) }
        }
    }

    private func finishPlaybackURLRequest(fileID: String, requestID: UUID,
                                          result: Result<URL, Error>) {
        guard let request = playbackURLRequests[fileID], request.id == requestID else { return }
        playbackURLRequests[fileID] = nil
        if case .success(let url) = result { cachePlaybackURL(url, for: fileID) }
        for waiter in request.waiters.values { waiter.resume(with: result) }
    }

    private func cancelPlaybackURLWaiter(fileID: String, waiterID: UUID) {
        guard var request = playbackURLRequests[fileID],
              let waiter = request.waiters.removeValue(forKey: waiterID) else { return }
        if request.waiters.isEmpty {
            playbackURLRequests[fileID] = nil
            request.task.cancel()
        } else {
            playbackURLRequests[fileID] = request
        }
        waiter.resume(throwing: CancellationError())
    }

    /// Stores a resolved URL, dropping entries past their TTL so the cache stays
    /// bounded to recently-viewed files over a long session.
    private func cachePlaybackURL(_ url: URL, for fileID: String) {
        let now = Date()
        playbackURLCache = playbackURLCache.filter { now.timeIntervalSince($0.value.fetchedAt) < playbackURLTTL }
        playbackURLCache[fileID] = (url, now)
    }

    /// Best-effort warm of the playback-URL cache for a file (e.g. on row
    /// hover), so a subsequent play skips the detail round-trip. No-op if
    /// already warm; ignores errors.
    public func prefetchPlaybackURL(fileID: String) async {
        _ = try? await playbackURL(fileID: fileID)
    }

    /// Read-only preparation while the user chooses Save / Save and Play.
    /// Refreshes expiring auth and locates an existing destination; never
    /// creates folders or offline tasks before the user's confirmation.
    public func prepareForCloudSave() async {
        if let preparation = folderPreparation { return await preparation.task.value }
        let id = UUID()
        let task = Task<Void, Never> {
            _ = try? await self.withSession {
                _ = try await self.auth.validAccessToken()
                guard self.cachedOfflineFolderID == nil else { return }
                let page = try await self.listPage(parentID: "", onlyCompleted: false, pageToken: "")
                guard self.cacheSessionGeneration == PikPakDriveOperation.sessionGeneration else { return }
                self.cachedOfflineFolderID = (page.files ?? []).map(\.asPikPakFile).first {
                    $0.isFolder && $0.name.caseInsensitiveCompare(self.offlineFolderName) == .orderedSame
                }?.id
            }
        }
        // Keep this work shared with a save that starts before preparation ends.
        folderPreparation = (id, task)
        await task.value
        if folderPreparation?.id == id { folderPreparation = nil }
    }

    /// Adds an offline-download task (magnet / torrent / direct URL) that saves
    /// into a named cloud folder (default "Pack From Shared", created if absent)
    /// so saved titles are grouped and readable. Returns the created task (its
    /// `fileID` is the cloud file, usable for playback once content arrives).
    /// Cloud playback can proceed while the best-effort folder move completes.
    @discardableResult
    public func offlineDownload(url: String, name: String = "", waitForFolderMove: Bool = true) async throws -> PikPakTask {
        try await withSession { try await self.offlineDownloadInSession(url: url, name: name, waitForFolderMove: waitForFolderMove) }
    }

    private func offlineDownloadInSession(url: String, name: String = "",
                                waitForFolderMove: Bool = true) async throws -> PikPakTask {
        let parent = try await offlineFolderID()
        Self.logger.info("offline download → folder \(self.offlineFolderName, privacy: .public) (\(parent, privacy: .public))")
        let request = OfflineDownloadRequest(
            name: name,
            url: .init(url: url),
            parent_id: parent,
            folder_type: "")
        let data = try await authorizedPost(path: "/drive/v1/files", body: request)
        let resp = try decode(OfflineDownloadResponse.self, from: data)
        guard let task = resp.task?.asTask else {
            throw PikPakError.api(code: -3, message: "PikPak 未返回离线任务")
        }
        // Safety net: PikPak doesn't always honour parent_id on an offline task
        // (the file can land at the drive root). Force the created file into the
        // target folder so saves are reliably grouped. Best-effort.
        if !task.fileID.isEmpty {
            // Once saved, finish filing even if the playback caller goes away.
            let move = Task {
                do { try await moveFiles(ids: [task.fileID], toParentID: parent) }
                catch { Self.logger.error("post-download move into folder failed: \(error.localizedDescription, privacy: .public)") }
            }
            if waitForFolderMove { await move.value }
        }
        return task
    }

    /// Moves files into a target folder (PikPak `files:batchMove`).
    public func moveFiles(ids: [String], toParentID: String) async throws -> Void {
        try await withSession { try await self.moveFilesInSession(ids: ids, toParentID: toParentID) }
    }

    private func moveFilesInSession(ids: [String], toParentID: String) async throws {
        guard !ids.isEmpty else { return }
        let body = BatchMoveRequest(ids: ids, to: .init(parent_id: toParentID))
        _ = try await authorizedPost(path: "/drive/v1/files:batchMove", body: body)
    }

    /// Id of the offline-download target folder, resolved (find-or-create) once
    /// and cached.
    private func offlineFolderID() async throws -> String {
        if let cached = cachedOfflineFolderID { return cached }
        if let preparation = folderPreparation {
            await preparation.task.value
            try Task.checkCancellation()
            if let generation = PikPakDriveOperation.sessionGeneration { try await checkSession(generation) }
            if let cached = cachedOfflineFolderID { return cached }
        }
        let id = try await findOrCreateFolder(named: offlineFolderName, parentID: "")
        guard cacheSessionGeneration == PikPakDriveOperation.sessionGeneration else {
            throw CancellationError()
        }
        cachedOfflineFolderID = id
        return id
    }

    private func findOrCreateFolder(named name: String, parentID: String) async throws -> String {
        // Unfiltered listing (not phase==COMPLETE) so an existing folder is
        // always found — otherwise we'd keep creating duplicate folders.
        var pageToken = ""
        repeat {
            let page = try await listPage(parentID: parentID, onlyCompleted: false, pageToken: pageToken)
            if let existing = (page.files ?? []).map(\.asPikPakFile).first(where: {
                $0.isFolder && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                return existing.id
            }
            pageToken = page.next_page_token ?? ""
        } while !pageToken.isEmpty
        let data = try await authorizedPost(path: "/drive/v1/files",
                                             body: CreateFolderRequest(parent_id: parentID, name: name))
        let resp = try decode(CreateFolderResponse.self, from: data)
        guard let id = resp.file?.id, !id.isEmpty else {
            throw PikPakError.api(code: -5, message: "无法创建文件夹「\(name)」")
        }
        return id
    }

    /// Polls a freshly-created file until it has a playable URL (content has
    /// started arriving), so an offline task can be "cloud-played" once ready.
    public func waitForPlayableURL(fileID: String, timeoutSeconds: Double = 40, pollSeconds: Double = 2) async throws -> URL {
        try await withSession { try await self.waitForPlayableURLInSession(fileID: fileID, timeoutSeconds: timeoutSeconds, pollSeconds: pollSeconds) }
    }

    private func waitForPlayableURLInSession(fileID: String, timeoutSeconds: Double = 40,
                                   pollSeconds: Double = 2) async throws -> URL {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { try await self.pollPlayableURL(fileID: fileID, pollSeconds: pollSeconds) }
            group.addTask {
                try await Task.sleep(for: .seconds(max(0, timeoutSeconds)))
                throw PikPakError.api(code: -4, message: "等待 PikPak 播放链接超时，请稍后在网盘中重试")
            }
            defer { group.cancelAll() }
            guard let url = try await group.next() else { throw CancellationError() }
            try Task.checkCancellation()
            return url
        }
    }

    private func pollPlayableURL(fileID: String, pollSeconds: Double) async throws -> URL {
        var transientFailures = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await playbackURL(fileID: fileID)
            } catch {
                try Task.checkCancellation()
                switch error {
                case PikPakError.api(code: -1, message: _),
                     PikPakError.api(code: 404, message: _),
                     PikPakError.http(status: 404):
                    // A new offline task can return its file ID before the file
                    // is queryable, including while its folder move completes.
                    // Only this new-file polling path waits for it to appear;
                    // the outer deadline still bounds the entire wait.
                    transientFailures = 0
                default:
                    guard Self.isRetryablePlaybackError(error), transientFailures < 2 else {
                        throw error
                    }
                    transientFailures += 1
                }
            }
            let delay = max(0.1, pollSeconds) * Double(1 << transientFailures)
            try await Task.sleep(for: .seconds(delay))
        }
    }

    private static func isRetryablePlaybackError(_ error: Error) -> Bool {
        switch error {
        case let error as URLError:
            return [.timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                    .dnsLookupFailed, .notConnectedToInternet].contains(error.code)
        case PikPakError.http(let status):
            return [408, 429, 500, 502, 503, 504].contains(status)
        case PikPakError.api(let code, _):
            return [10, 408, 429, 500, 502, 503, 504].contains(code)
        default:
            return false
        }
    }

    /// Polls a freshly-downloaded file until it exposes a **streaming** media
    /// link — the same fast path the file browser plays — so cloud-playing a
    /// Mikan save streams as smoothly as playing an already-complete file
    /// (rather than the slow raw download link of a still-finalizing file). If
    /// no streaming link appears within the timeout, falls back to any playable
    /// URL so playback still starts.
    public func waitForStreamablePlaybackURL(fileID: String, timeoutSeconds: Double = 90, pollSeconds: Double = 2) async throws -> URL {
        try await withSession { try await self.waitForStreamablePlaybackURLInSession(fileID: fileID, timeoutSeconds: timeoutSeconds, pollSeconds: pollSeconds) }
    }

    private func waitForStreamablePlaybackURLInSession(fileID: String, timeoutSeconds: Double = 90,
                                             pollSeconds: Double = 2) async throws -> URL {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            guard let generation = PikPakDriveOperation.sessionGeneration else {
                throw CancellationError()
            }
            try await checkSession(generation)
            if let file = try? await fetchFile(fileID), let url = file.streamingURL {
                cachePlaybackURL(url, for: fileID)           // warm cache so a later click is instant
                return url
            }
            if Date() >= deadline {
                return try await playbackURL(fileID: fileID, allowCached: false)
            }
            try await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
        }
    }

    // MARK: - Offline-task center

    /// Lists offline-download tasks in the given phases. Defaults to the
    /// active / failed set worth surfacing in the task center — completed
    /// downloads already live in the file browser. Follows pagination.
    public func tasks(phases: [String] = ["PHASE_TYPE_RUNNING", "PHASE_TYPE_PENDING", "PHASE_TYPE_ERROR"]) async throws -> [PikPakTask] {
        try await withSession { try await self.tasksInSession(phases: phases) }
    }

    private func tasksInSession(phases: [String] = ["PHASE_TYPE_RUNNING", "PHASE_TYPE_PENDING", "PHASE_TYPE_ERROR"])
        async throws -> [PikPakTask] {
        var result: [PikPakTask] = []
        var pageToken: String? = ""
        repeat {
            let resp = try await taskPage(phases: phases, pageToken: pageToken ?? "")
            result.append(contentsOf: (resp.tasks ?? []).map(\.asTask))
            let next = resp.next_page_token
            pageToken = (next?.isEmpty == false) ? next : nil
        } while pageToken != nil
        return result
    }

    public func task(id: String) async throws -> PikPakTask? {
        try await withSession {
            var pageToken = ""
            repeat {
                let page = try await self.taskPage(phases: nil, pageToken: pageToken)
                if let match = page.tasks?.first(where: { $0.id == id }) {
                    return match.asTask
                }
                pageToken = page.next_page_token ?? ""
            } while !pageToken.isEmpty
            return nil
        }
    }

    private func taskPage(phases: [String]?, pageToken: String) async throws -> PPTasksResponse {
        var query = ["type": "offline", "thumbnail_size": "SIZE_SMALL",
                     "limit": "100", "page_token": pageToken]
        if let phases {
            query["filters"] = #"{"phase":{"in":""# + phases.joined(separator: ",") + #""}}"#
        }
        let data = try await authorizedGet(path: "/drive/v1/tasks", query: query)
        return try decode(PPTasksResponse.self, from: data)
    }

    /// Removes an offline task. `deleteFiles` also trashes any partial file it
    /// already produced.
    public func deleteTask(id: String, deleteFiles: Bool = false) async throws -> Void {
        try await withSession { try await self.deleteTaskInSession(id: id, deleteFiles: deleteFiles) }
    }

    private func deleteTaskInSession(id: String, deleteFiles: Bool = false) async throws {
        _ = try await authorizedDelete(path: "/drive/v1/tasks",
                                       query: ["task_ids": id,
                                               "delete_files": deleteFiles ? "true" : "false"])
    }

    /// Retries a failed task by re-submitting its original source URL. PikPak
    /// has no stable retry endpoint; re-adding the magnet/URL is what its own
    /// client effectively does (and it dedups server-side). Clears the failed
    /// task first so it doesn't linger in the list.
    @discardableResult
    public func retryTask(_ task: PikPakTask) async throws -> PikPakTask {
        try await withSession { try await self.retryTaskInSession(task) }
    }

    private func retryTaskInSession(_ task: PikPakTask) async throws -> PikPakTask {
        guard let url = task.sourceURL, !url.isEmpty else {
            throw PikPakError.api(code: -6, message: "无法重试该任务：缺少原始下载链接")
        }
        try? await deleteTask(id: task.id)
        return try await offlineDownload(url: url)
    }

    // MARK: - Session validation

    /// What one authenticated probe of `/drive/v1/about` could determine.
    public enum SessionVerification: Sendable, Equatable {
        /// PikPak accepted the session.
        case valid
        /// PikPak actively rejected the tokens — the session is unrecoverable
        /// and its web data should be wiped so a fresh login starts clean.
        case dead
        /// Transport / decoding trouble — PikPak was never really asked. The
        /// session must NOT be torn down: the failure says nothing about its
        /// validity, and wiping persisted state here is what used to turn one
        /// network blip into "log in again on every launch".
        case unavailable
    }

    /// Cheapest authenticated call PikPak offers (`/drive/v1/about`, the quota
    /// endpoint). Used after a silently restored web session is adopted: a set
    /// of stale tokens must not leave the UI claiming "signed in" and then fail
    /// on every listing. Never throws — the caller's only decision is "keep
    /// this session, wipe it, or keep it and retry later".
    public func verifySession() async -> SessionVerification {
        do {
            _ = try await authorizedGet(path: "/drive/v1/about", query: [:])
            return .valid
        } catch {
            Self.logger.info("session verification failed: \(error.localizedDescription, privacy: .public)")
            return Self.classifyVerificationFailure(error)
        }
    }

    /// Splits a verification failure into "PikPak rejected the session" (dead)
    /// and "we could not reach / understand PikPak" (unavailable). Mirrors the
    /// dead-token classification in PikPakAuth.postRefresh.
    static func classifyVerificationFailure(_ error: Error) -> SessionVerification {
        switch error {
        case let pikPak as PikPakError:
            switch pikPak {
            case .notAuthenticated:
                return .dead
            case .api(let code, let message):
                let dead = code == 4126 || code == 4121 || code == 16
                    || message.lowercased().contains("invalid_grant")
                return dead ? .dead : .unavailable
            case .http(let status):
                return (status == 401 || status == 403) ? .dead : .unavailable
            case .transport, .decoding, .captchaRequired, .missingCredentials:
                return .unavailable
            }
        default:
            return .unavailable
        }
    }

    // MARK: - Request plumbing

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw PikPakError.decoding(String(data: data, encoding: .utf8) ?? "\(error)") }
    }

    private func authorizedGet(path: String, query: [String: String]) async throws -> Data {
        let url = buildURL(path: path, query: query)
        let action = PikPakCrypto.action(method: "GET", url: url)
        return try await authorized(action: action) { try await self.http.getJSON(url, headers: $0) }
    }

    private func authorizedPost<Body: Encodable>(path: String, body: Body) async throws -> Data {
        let url = buildURL(path: path, query: [:])
        let action = PikPakCrypto.action(method: "POST", url: url)
        let encoded = try JSONEncoder().encode(body)
        return try await authorized(action: action) { try await self.http.postJSON(url, body: encoded, headers: $0) }
    }

    private func authorizedDelete(path: String, query: [String: String]) async throws -> Data {
        let url = buildURL(path: path, query: query)
        let action = PikPakCrypto.action(method: "DELETE", url: url)
        return try await authorized(action: action) { try await self.http.deleteJSON(url, headers: $0) }
    }

    /// Runs an authorized request, applying PikPak's error-code retry policy
    /// (token refresh on 16/4121/4122, captcha re-sign on 9) up to a small
    /// budget. `perform` is the bare HTTP call given the auth headers.
    private func authorized(action: String,
                            _ perform: (_ headers: [String: String]) async throws -> (Data, Int)) async throws -> Data {
        try await withSession { try await self.authorizedInSession(action: action, perform) }
    }

    private func authorizedInSession(action: String,
                            _ perform: (_ headers: [String: String]) async throws -> (Data, Int)) async throws -> Data {
        // Seed with the captcha token captured at web login, so the first call
        // already carries a valid one (no salt-dependent re-sign needed).
        guard let generation = PikPakDriveOperation.sessionGeneration else {
            throw CancellationError()
        }
        var triedRefresh = false
        var triedCaptcha = false

        while true {
            try await checkSession(generation)
            let headers = try await auth.requestHeaders(generation: generation)
            try await checkSession(generation)
            let (data, status) = try await perform(headers)
            try await checkSession(generation)
            guard let code = errorCode(in: data, status: status) else { return data }

            switch code {
            case 16, 4121, 4122:                             // access token expired
                guard !triedRefresh else { throw apiError(in: data, status: status, code: code) }
                triedRefresh = true
                _ = try await auth.refreshAccessToken(expectedGeneration: generation)
            case 9:                                          // captcha token expired
                guard !triedCaptcha else { throw apiError(in: data, status: status, code: code) }
                triedCaptcha = true
                // Self-sign a fresh captcha token first (one cheap round trip).
                // If PikPak rejects it the salts in PikPakConfig have rotated,
                // so fall back to the offscreen re-capture: it loads the web
                // client in the shared *persistent* data store, where the login
                // cookies live, and lifts a PikPak-minted token off the SPA's
                // own traffic. Only when both fail do we prompt a re-login.
                do {
                    _ = try await auth.captchaToken(forAction: action, refresh: true,
                                                   expectedGeneration: generation)
                } catch {
                    try await checkSession(generation)
                    do {
                        _ = try await auth.recaptureCaptchaToken(expectedGeneration: generation)
                    } catch {
                        try await checkSession(generation)
                        throw PikPakError.captchaRequired("PikPak 验证已过期，请重新登录 PikPak。")
                    }
                }
            default:
                throw apiError(in: data, status: status, code: code)
            }
        }
    }

    private func buildURL(path: String, query: [String: String]) -> URL {
        let base = config.driveBaseURL.appendingPathComponent(path.hasPrefix("/")
            ? String(path.dropFirst()) : path)
        guard !query.isEmpty,
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps.url ?? base
    }

    /// Returns PikPak's error_code if the body is an error envelope (or the HTTP
    /// status if non-2xx with no envelope), else nil for success.
    private func errorCode(in data: Data, status: Int) -> Int? {
        if let envelope = try? JSONDecoder().decode(PikPakErrorResponse.self, from: data),
           let code = envelope.error_code, code != 0 {
            return code
        }
        return status >= 400 ? status : nil
    }

    private func apiError(in data: Data, status: Int, code: Int) -> PikPakError {
        let envelope = try? JSONDecoder().decode(PikPakErrorResponse.self, from: data)
        let message = envelope?.error_description?.nonEmpty ?? envelope?.error?.nonEmpty
            ?? "PikPak 返回错误（\(code)）"
        // Keep missing-file responses recognizable even when PikPak supplies
        // its own error_code instead of the HTTP status. Preserve its message.
        let notFound = status == 404
            || ["not_found", "file_not_found", "folder_not_found"].contains(envelope?.error ?? "")
            || message.contains("文件或文件夹不存在")
        return .api(code: notFound ? 404 : code, message: message)
    }
}

// MARK: - Wire DTOs

struct PPFilesResponse: Decodable {
    let files: [PPFile]?
    let next_page_token: String?
}

struct PPFile: Decodable {
    let id: String
    let kind: String?
    let name: String
    let size: String?
    let mime_type: String?
    let thumbnail_link: String?
    let web_content_link: String?
    let modified_time: String?
    let medias: [PPMedia]?

    var asPikPakFile: PikPakFile {
        PikPakFile(id: id,
                   name: name,
                   isFolder: kind == "drive#folder",
                   size: Int64(size ?? "") ?? 0,
                   mimeType: mime_type,
                   thumbnailURL: thumbnail_link.flatMap(URL.init(string:)),
                   modifiedTime: PPFile.date(from: modified_time))
    }

    /// The streaming `medias` link PikPak's own player uses (it starts faster
    /// and seeks better than the raw download URL): origin first to keep
    /// original quality, then the default rendition, then any. Nil until the
    /// file is complete enough to have renditions.
    var streamingURL: URL? {
        let candidates = medias ?? []
        let pick = candidates.first(where: { $0.is_origin == true && $0.link?.url?.nonEmpty != nil })
            ?? candidates.first(where: { $0.is_default == true && $0.link?.url?.nonEmpty != nil })
            ?? candidates.first(where: { $0.link?.url?.nonEmpty != nil })
        if let s = pick?.link?.url?.nonEmpty, let url = URL(string: s) { return url }
        return nil
    }

    /// A playable URL: the streaming link when available, else the raw
    /// `web_content_link` (the only option for a still-finalizing file).
    var bestPlaybackURL: URL? {
        if let streaming = streamingURL { return streaming }
        if let link = web_content_link?.nonEmpty, let url = URL(string: link) { return url }
        return nil
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func date(from string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

struct PPMedia: Decodable {
    let is_origin: Bool?
    let is_default: Bool?
    let resolution_name: String?
    let link: PPMediaLink?
}

struct PPMediaLink: Decodable {
    let url: String?
}

struct OfflineDownloadRequest: Encodable {
    let kind = "drive#file"
    let name: String
    let upload_type = "UPLOAD_TYPE_URL"
    let url: URLField
    let parent_id: String
    let folder_type: String
    struct URLField: Encodable { let url: String }
}

struct CreateFolderRequest: Encodable {
    let kind = "drive#folder"
    let parent_id: String
    let name: String
}

struct BatchMoveRequest: Encodable {
    let ids: [String]
    let to: To
    struct To: Encodable { let parent_id: String }
}

struct CreateFolderResponse: Decodable {
    let file: PPFile?
}

struct OfflineDownloadResponse: Decodable {
    let task: PPTask?
}

struct PPTasksResponse: Decodable {
    let tasks: [PPTask]?
    let next_page_token: String?
}

struct PPTask: Decodable {
    let id: String?
    let file_id: String?
    let file_name: String?
    let name: String?
    let phase: String?
    let progress: Int?
    let file_size: String?
    let message: String?
    let created_time: String?
    let params: PPTaskParams?

    var asTask: PikPakTask {
        PikPakTask(id: id ?? "",
                   fileID: file_id ?? "",
                   name: file_name?.nonEmpty ?? name ?? "",
                   phase: phase ?? "",
                   progress: progress ?? 0,
                   fileSize: Int64(file_size ?? "") ?? 0,
                   message: message?.nonEmpty,
                   sourceURL: params?.url?.nonEmpty,
                   createdTime: PPFile.date(from: created_time))
    }
}

struct PPTaskParams: Decodable {
    let url: String?
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

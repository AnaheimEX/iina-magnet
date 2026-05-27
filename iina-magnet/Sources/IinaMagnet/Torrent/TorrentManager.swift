//
//  TorrentManager.swift
//  IinaMagnet
//
//  Swift actor wrapping LMSession. Public surface is async; all libtorrent
//  access is serialized on the actor.
//
//  Responsibilities:
//    - addMagnet / addTorrentFile / pause / resume / remove
//    - setPieceDeadline + setSequentialDownload for stream-while-download
//    - Alert pumping (50ms) → broadcast TorrentEvent stream
//    - Mirror libtorrent status into SwiftData TorrentTask on every pump
//    - Restore unfinished tasks on start (resume from disk)
//
//  Lifecycle:
//    IinaMagnetBootstrap.start → TorrentManager.shared.start()
//    IinaMagnetBootstrap.shutdown → .shutdown()

import Foundation
import SwiftData
import OSLog
import LibtorrentBridge

// LMSession is owned exclusively by TorrentManager and never touched off-actor.
extension LMSession: @unchecked @retroactive Sendable {}

public actor TorrentManager {

    public static let shared: TorrentManager = TorrentManager()

    private static let logger = Logger(subsystem: "iina-magnet", category: "torrent")

    private let session: LMSession
    private let persistence: PersistenceController
    private var modelContext: ModelContext?
    private var continuations: [UUID: AsyncStream<TorrentEvent>.Continuation] = [:]
    private var pumpTask: Task<Void, Never>?
    private var didStart = false

    /// Pump cadence; tuned in ADR-0002. 50ms balances responsiveness vs CPU.
    private let pumpIntervalNs: UInt64 = 50_000_000

    private init() {
        self.persistence = PersistenceController.shared
        self.session = LMSession(settings: .default())
    }

    /// For tests — injects a custom session + persistence.
    public init(session: LMSession, persistence: PersistenceController) {
        self.session = session
        self.persistence = persistence
    }

    // MARK: Lifecycle

    public func start() async {
        guard !didStart else { return }
        didStart = true
        modelContext = ModelContext(persistence.container)
        startPumping()
        Self.logger.info("TorrentManager started")
    }

    public func shutdown() async {
        guard didStart else { return }
        didStart = false
        pumpTask?.cancel()
        pumpTask = nil
        for (_, cont) in continuations { cont.finish() }
        continuations.removeAll()
        Self.logger.info("TorrentManager shutdown")
    }

    // MARK: Public API

    public func addMagnet(_ uri: String, savePath: URL) async throws -> InfoHash {
        let hex = try session.addMagnet(uri, savePath: savePath.path)
        let hash = InfoHash(hex)
        upsertTask(infoHash: hash, savePath: savePath, displayName: hex, status: .resolving)
        return hash
    }

    public func addTorrentFile(_ data: Data, savePath: URL) async throws -> InfoHash {
        let hex = try session.addTorrentFile(data, savePath: savePath.path)
        let hash = InfoHash(hex)
        upsertTask(infoHash: hash, savePath: savePath, displayName: hex, status: .resolving)
        return hash
    }

    public func pause(_ hash: InfoHash) async {
        session.pauseTorrent(hash.hex)
    }

    public func resume(_ hash: InfoHash) async {
        session.resumeTorrent(hash.hex)
    }

    public func remove(_ hash: InfoHash, deleteFiles: Bool) async {
        session.removeTorrent(hash.hex, deleteFiles: deleteFiles)
        deleteTask(infoHash: hash)
    }

    public func setPieceDeadline(_ hash: InfoHash, piece: Int, deadlineMs: Int) async {
        session.setPieceDeadline(hash.hex, piece: Int32(piece), deadlineMs: Int32(deadlineMs))
    }

    public func setSequentialDownload(_ hash: InfoHash, enabled: Bool) async {
        session.setSequentialDownload(hash.hex, enabled: enabled)
    }

    public func status(of hash: InfoHash) async -> LMTorrentStatus? {
        session.status(of: hash.hex)
    }

    public func allStatuses() async -> [LMTorrentStatus] {
        session.allStatuses()
    }

    // MARK: Events stream

    /// Returns a fresh AsyncStream. Each call is a new subscriber; the actor
    /// fans events out to all live continuations.
    public nonisolated func events() -> AsyncStream<TorrentEvent> {
        let (stream, continuation) = AsyncStream<TorrentEvent>.makeStream()
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        Task { await self.addContinuation(id, continuation: continuation) }
        return stream
    }

    private func addContinuation(_ id: UUID, continuation: AsyncStream<TorrentEvent>.Continuation) {
        continuations[id] = continuation
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func broadcast(_ event: TorrentEvent) {
        for (_, cont) in continuations { cont.yield(event) }
    }

    // MARK: Pumping

    private func startPumping() {
        pumpTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.pumpIntervalNs)
                await self.pumpOnce()
            }
        }
    }

    private func pumpOnce() {
        let alerts = session.pumpAlerts()
        for alert in alerts {
            guard let event = mapAlertToEvent(alert) else { continue }
            broadcast(event)
            applyEventToTask(event)
        }
        refreshTaskStatuses()
    }

    private func mapAlertToEvent(_ alert: LMAlert) -> TorrentEvent? {
        guard let hex = alert.infoHash else { return nil }
        let hash = InfoHash(hex)
        switch alert.type {
        case .metadataReceived: return .metadataReceived(hash)
        case .pieceFinished:    return .pieceFinished(hash, pieceIndex: Int(alert.extraInt))
        case .fileCompleted:    return .fileCompleted(hash, fileIndex: Int(alert.extraInt))
        case .torrentFinished:  return .torrentFinished(hash)
        case .torrentError:     return .torrentError(hash, message: alert.message)
        case .saveResumeData:   return .saveResumeData(hash)
        case .other:            return nil
        @unknown default:       return nil
        }
    }

    private func applyEventToTask(_ event: TorrentEvent) {
        guard let ctx = modelContext else { return }
        let hashHex: String
        switch event {
        case .metadataReceived(let h), .pieceFinished(let h, _), .fileCompleted(let h, _),
             .torrentFinished(let h), .torrentError(let h, _), .saveResumeData(let h):
            hashHex = h.hex
        }
        let pred = #Predicate<TorrentTask> { $0.infoHash == hashHex }
        guard let task = try? ctx.fetch(FetchDescriptor(predicate: pred)).first else { return }

        switch event {
        case .metadataReceived:
            if task.status == .resolving { task.status = .downloading }
        case .torrentFinished:
            task.status = .completed
            task.progress = 1.0
        case .torrentError(_, let message):
            task.status = .failed
            Self.logger.error("torrent \(hashHex, privacy: .public) error: \(message, privacy: .public)")
        default:
            break
        }
        task.updatedAt = Date()
        try? ctx.save()
    }

    private func refreshTaskStatuses() {
        guard let ctx = modelContext else { return }
        let statuses = session.allStatuses()
        var anyChanged = false
        for status in statuses {
            let hashHex = status.infoHash
            let pred = #Predicate<TorrentTask> { $0.infoHash == hashHex }
            guard let task = try? ctx.fetch(FetchDescriptor(predicate: pred)).first else { continue }

            let mapped: TorrentTaskStatus = {
                switch status.state {
                case .resolving:   return .resolving
                case .downloading: return .downloading
                case .paused:      return .paused
                case .seeding:     return .seeding
                case .completed:   return .completed
                case .failed:      return .failed
                case .removed:     return .removed
                @unknown default:  return .downloading
                }
            }()
            if task.statusRaw != mapped.rawValue {
                task.status = mapped
                anyChanged = true
            }
            if abs(task.progress - status.progress) > 0.001 {
                task.progress = status.progress
                anyChanged = true
            }
            if task.totalSizeBytes != status.totalSize {
                task.totalSizeBytes = status.totalSize
                anyChanged = true
            }
            if task.downloadedBytes != status.downloadedBytes {
                task.downloadedBytes = status.downloadedBytes
                anyChanged = true
            }
            if anyChanged { task.updatedAt = Date() }
        }
        if anyChanged { try? ctx.save() }
    }

    // MARK: Persistence helpers

    private func upsertTask(infoHash hash: InfoHash, savePath: URL, displayName: String, status: TorrentTaskStatus) {
        guard let ctx = modelContext else { return }
        let hashHex = hash.hex
        let pred = #Predicate<TorrentTask> { $0.infoHash == hashHex }
        if let existing = try? ctx.fetch(FetchDescriptor(predicate: pred)).first {
            existing.savePath = savePath
            existing.displayName = displayName
            existing.status = status
            existing.updatedAt = Date()
        } else {
            let task = TorrentTask(infoHash: hash.hex,
                                   savePath: savePath,
                                   displayName: displayName,
                                   status: status)
            ctx.insert(task)
        }
        try? ctx.save()
    }

    private func deleteTask(infoHash hash: InfoHash) {
        guard let ctx = modelContext else { return }
        let hashHex = hash.hex
        let pred = #Predicate<TorrentTask> { $0.infoHash == hashHex }
        if let existing = try? ctx.fetch(FetchDescriptor(predicate: pred)).first {
            ctx.delete(existing)
            try? ctx.save()
        }
    }
}

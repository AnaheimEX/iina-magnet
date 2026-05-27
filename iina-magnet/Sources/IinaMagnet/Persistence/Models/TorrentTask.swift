//
//  TorrentTask.swift
//  IinaMagnet
//
//  Persisted representation of a libtorrent task. Mirrored from LMTorrentStatus
//  on every alert pump so the UI (Phase 1 issue 15) can @Query the table.
//
//  Lifecycle:
//    - Created when TorrentManager.addMagnet / addTorrentFile succeeds
//    - Updated by TorrentManager from alert pumping
//    - Deleted by TorrentManager.remove (optionally with the files)

import Foundation
import SwiftData

public enum TorrentTaskStatus: Int, Codable, Sendable {
    case resolving    = 0
    case downloading  = 1
    case paused       = 2
    case seeding      = 3
    case completed    = 4
    case failed       = 5
    case removed      = 6
}

@Model
public final class TorrentTask {

    @Attribute(.unique) public var infoHash: String
    public var savePath: URL
    public var displayName: String
    public var statusRaw: Int           // TorrentTaskStatus.rawValue
    public var progress: Double         // 0.0 - 1.0
    public var totalSizeBytes: Int64
    public var downloadedBytes: Int64
    public var addedAt: Date
    public var updatedAt: Date

    public var status: TorrentTaskStatus {
        get { TorrentTaskStatus(rawValue: statusRaw) ?? .resolving }
        set { statusRaw = newValue.rawValue }
    }

    public init(infoHash: String,
                savePath: URL,
                displayName: String,
                status: TorrentTaskStatus = .resolving,
                progress: Double = 0.0,
                totalSizeBytes: Int64 = 0,
                downloadedBytes: Int64 = 0) {
        self.infoHash = infoHash
        self.savePath = savePath
        self.displayName = displayName
        self.statusRaw = status.rawValue
        self.progress = progress
        self.totalSizeBytes = totalSizeBytes
        self.downloadedBytes = downloadedBytes
        let now = Date()
        self.addedAt = now
        self.updatedAt = now
    }
}

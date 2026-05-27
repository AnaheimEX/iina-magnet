//
//  StreamCoordinator.swift
//  IinaMagnet
//
//  Drives the streaming optimization for a single in-flight torrent.
//  Periodically:
//    1) Reads the player's current byte offset (via PlayerPositionOracle)
//    2) Fetches the torrent's current status from TorrentManager
//    3) Runs StreamPlanner to compute piece deadlines
//    4) Applies them via TorrentManager.setPieceDeadline
//
//  Lifecycle:
//    - Created when the user starts playing a torrent file
//    - Cancelled when playback stops or coordinator deinit

import Foundation
import OSLog

/// Abstraction over iina's mpv-backed player so this module is testable.
/// Returns the player's current position in seconds, or nil if unknown.
public protocol PlayerPositionOracle: Sendable {
    func currentPositionSeconds() async -> Double?
}

public actor StreamCoordinator {

    private static let logger = Logger(subsystem: "iina-magnet", category: "stream")

    public let infoHash: InfoHash
    public let videoFileSizeBytes: Int64
    public let videoFileStartOffsetInTorrent: Int64
    public let bitrateBytesPerSec: Int

    private let torrentManager: TorrentManager
    private let oracle: any PlayerPositionOracle
    private let pollInterval: TimeInterval

    private var pollTask: Task<Void, Never>?
    private var didStart = false

    public init(infoHash: InfoHash,
                videoFileSizeBytes: Int64,
                videoFileStartOffsetInTorrent: Int64 = 0,
                bitrateBytesPerSec: Int = 2 * 1024 * 1024,
                torrentManager: TorrentManager = .shared,
                oracle: any PlayerPositionOracle,
                pollInterval: TimeInterval = 1.0) {
        self.infoHash = infoHash
        self.videoFileSizeBytes = videoFileSizeBytes
        self.videoFileStartOffsetInTorrent = videoFileStartOffsetInTorrent
        self.bitrateBytesPerSec = bitrateBytesPerSec
        self.torrentManager = torrentManager
        self.oracle = oracle
        self.pollInterval = pollInterval
    }

    public func start() async {
        guard !didStart else { return }
        didStart = true
        await torrentManagerSetSequential(true)
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.tickOnce()
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
        Self.logger.info("StreamCoordinator started for \(self.infoHash.hex, privacy: .public)")
    }

    public func stop() {
        guard didStart else { return }
        didStart = false
        pollTask?.cancel()
        pollTask = nil
        Self.logger.info("StreamCoordinator stopped for \(self.infoHash.hex, privacy: .public)")
    }

    // MARK: - Tick

    private func tickOnce() async {
        guard let positionSec = await oracle.currentPositionSeconds() else { return }
        let positionBytes = Int64(positionSec * Double(bitrateBytesPerSec))

        guard let status = await torrentManager.status(of: infoHash) else { return }
        guard status.pieceLength > 0 else { return }

        let pieceMap = makePieceMap(from: status)
        let deadlines = StreamPlanner.plan(
            playerOffsetBytes: positionBytes,
            videoFileSizeBytes: videoFileSizeBytes,
            videoFileStartOffsetInTorrent: videoFileStartOffsetInTorrent,
            pieceMap: pieceMap,
            windows: PlannerWindows(urgentSeconds: 30, nearSeconds: 60, farSeconds: 120,
                                    bitrateBytesPerSec: bitrateBytesPerSec)
        )
        for d in deadlines {
            await torrentManager.setPieceDeadline(infoHash, piece: d.piece, deadlineMs: d.deadlineMs)
        }
    }

    private func makePieceMap(from status: LMTorrentStatus) -> PieceMap {
        let bytes = status.pieces.withUnsafeBytes { Array($0) }
        var done: Set<Int> = []
        for (i, b) in bytes.enumerated() where b != 0 { done.insert(i) }
        return PieceMap(pieceLength: Int(status.pieceLength),
                        totalPieces: Int(status.numPieces),
                        downloaded: done)
    }

    private func torrentManagerSetSequential(_ enabled: Bool) async {
        await torrentManager.setSequentialDownload(infoHash, enabled: enabled)
    }
}

// MARK: - Imported types

import LibtorrentBridge

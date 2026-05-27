//
//  MagnetRouter.swift
//  IinaMagnet
//
//  Single entry point for "play this torrent file". Wires together:
//    - Sparse-file path lookup
//    - TorrentManager.setSequentialDownload
//    - iina PlayerCore.openURL (via IinaBridge)
//    - StreamCoordinator lifecycle (one per active playback)

import Foundation
import OSLog
import SwiftData
import LibtorrentBridge

@MainActor
public final class MagnetRouter {

    public static let shared = MagnetRouter()
    private static let logger = Logger(subsystem: "iina-magnet", category: "router")

    private var activeCoordinators: [String: StreamCoordinator] = [:]

    private init() {}

    /// Play the first video file of a torrent, with streaming optimization on.
    /// If the torrent has multiple video files, picks the largest one.
    public func playStreaming(infoHash: InfoHash) async {
        guard let bridge = IinaBridgeRegistry.bridge else {
            Self.logger.error("no IinaBridge registered; cannot start playback")
            return
        }
        guard let status = await TorrentManager.shared.status(of: infoHash) else {
            Self.logger.error("no status for \(infoHash.hex, privacy: .public)")
            return
        }

        // Locate the on-disk path. Pull saveDir from the persisted TorrentTask.
        let ctx = ModelContext(PersistenceController.shared.container)
        let hashHex = infoHash.hex
        let pred = #Predicate<TorrentTask> { $0.infoHash == hashHex }
        guard let task = try? ctx.fetch(FetchDescriptor(predicate: pred)).first else {
            Self.logger.error("no TorrentTask for \(infoHash.hex, privacy: .public)")
            return
        }

        // Pick the largest video file under task.savePath. If we can't find one
        // (e.g. metadata not yet resolved), fall back to the directory itself.
        let videoURL = await findLargestVideo(in: task.savePath) ?? task.savePath
        Self.logger.info("opening \(videoURL.path, privacy: .public) for streaming")

        let videoSize = (try? FileManager.default.attributesOfItem(atPath: videoURL.path))
            .flatMap { $0[.size] as? Int64 } ?? status.totalSize

        // Stop any existing coordinator for this hash before spawning a new one.
        if let existing = activeCoordinators[infoHash.hex] {
            await existing.stop()
        }
        let coordinator = StreamCoordinator(
            infoHash: infoHash,
            videoFileSizeBytes: videoSize,
            torrentManager: .shared,
            oracle: BridgeOracle()
        )
        activeCoordinators[infoHash.hex] = coordinator
        await coordinator.start()

        bridge.openForPlayback(videoURL)
    }

    /// Stop the streaming coordinator for an info-hash (called when removing
    /// torrent or stopping playback).
    public func stopStreaming(infoHash: InfoHash) async {
        if let coordinator = activeCoordinators.removeValue(forKey: infoHash.hex) {
            await coordinator.stop()
        }
    }

    private func findLargestVideo(in dir: URL) async -> URL? {
        let exts = SubtitleExtractor.videoExtensions
        let fm = FileManager.default
        guard let it = fm.enumerator(at: dir,
                                     includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                     options: []) else { return nil }
        var best: (URL, Int64)?
        for case let url as URL in it {
            guard exts.contains(url.pathExtension.lowercased()),
                  let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  attrs.isRegularFile == true,
                  let size = attrs.fileSize else { continue }
            if best == nil || Int64(size) > best!.1 {
                best = (url, Int64(size))
            }
        }
        return best?.0
    }
}

// MARK: - Oracle bridging

private struct BridgeOracle: PlayerPositionOracle {
    func currentPositionSeconds() async -> Double? {
        await MainActor.run { IinaBridgeRegistry.bridge?.currentVideoPositionSec }
    }
}

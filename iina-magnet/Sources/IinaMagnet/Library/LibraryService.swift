//
//  LibraryService.swift
//  IinaMagnet
//
//  Phase 2 (Issue 04). Owns scan roots, walks them for video files, and emits
//  scan candidates. Pure of SwiftData — it produces `ScannedFile`s + fingerprints;
//  the Ingester (Issue 12) reconciles them against the store. Incremental
//  watching is handled by FSEventsWatcher and routed back here.

import Foundation
import OSLog

/// One video file found by a scan, already parsed.
public struct ScannedFile: Sendable, Equatable {
    public let url: URL
    public let fileFingerprint: String   // "<st_dev>:<st_ino>:<size>"
    public let sizeBytes: Int64
    public let parsed: ParsedMedia
}

/// Progress event from a scan. `file` is nil for entries that couldn't be
/// stat'd; `current == nil` only on the synthetic terminal tick.
public struct ScanProgress: Sendable {
    public let scanned: Int
    public let total: Int
    public let current: URL?
    public let file: ScannedFile?
}

public actor LibraryService {

    public static let shared = LibraryService()

    private static let logger = Logger(subsystem: "iina-magnet", category: "library")

    /// Video container extensions we ingest (PRD §IM-5).
    public static let videoExtensions: Set<String> =
        ["mkv", "mp4", "m4v", "mov", "avi", "ts", "flv", "webm", "wmv", "rmvb"]

    private(set) var scanRoots: [URL]

    public init(scanRoots: [URL] = []) {
        self.scanRoots = scanRoots
    }

    public func setScanRoots(_ roots: [URL]) { scanRoots = roots }

    public func addScanRoot(_ url: URL) {
        if !scanRoots.contains(url) { scanRoots.append(url) }
    }

    public func removeScanRoot(_ url: URL) {
        scanRoots.removeAll { $0 == url }
    }

    /// Full scan of the configured roots.
    public func fullScan() -> AsyncStream<ScanProgress> {
        Self.scan(roots: scanRoots)
    }

    // MARK: - Pure / nonisolated scanning

    /// Full scan of explicit roots. Off-actor so a long walk never blocks the
    /// actor; cancel by tearing down the stream's consumer.
    public nonisolated static func scan(roots: [URL]) -> AsyncStream<ScanProgress> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                let files = roots.flatMap { enumerateVideos(under: $0) }
                let total = files.count
                var scanned = 0
                for url in files {
                    if Task.isCancelled { break }
                    scanned += 1
                    if let (fp, size) = fingerprint(path: url.path) {
                        let parsed = FilenameParser.parse(url.lastPathComponent)
                        let file = ScannedFile(url: url, fileFingerprint: fp,
                                               sizeBytes: size, parsed: parsed)
                        continuation.yield(.init(scanned: scanned, total: total,
                                                 current: url, file: file))
                    } else {
                        continuation.yield(.init(scanned: scanned, total: total,
                                                 current: url, file: nil))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Compares the fingerprints just seen against those already in the store.
    /// `new` need inserting; `missing` are store rows whose files weren't found
    /// (Issue 12 marks them `isMissing`, doesn't delete).
    public nonisolated static func reconcile(known: Set<String>,
                                             seen: Set<String>) -> (new: Set<String>, missing: Set<String>) {
        (new: seen.subtracting(known), missing: known.subtracting(seen))
    }

    /// Depth-first video file walk; skips hidden files (.DS_Store etc.) and
    /// anything not on the extension whitelist.
    nonisolated static func enumerateVideos(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root,
                                     includingPropertiesForKeys: [.isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else {
            return []
        }
        var out: [URL] = []
        for case let url as URL in en {
            if videoExtensions.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// `(dev:ino:size)` fingerprint via `stat`. Atomic read of all three so a
    /// re-scan of an unchanged file produces the same key (dedup, PRD §IM-5).
    nonisolated static func fingerprint(path: String) -> (String, Int64)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let fp = "\(st.st_dev):\(st.st_ino):\(st.st_size)"
        return (fp, Int64(st.st_size))
    }
}

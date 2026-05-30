//
//  LibraryPlayback.swift
//  IinaMagnet
//
//  Opens a library file in iina (Issue 14). Reuses the Phase 1 IinaBridge — no
//  new bridge — and handles the security-scoped bookmark + missing-file guard so
//  the archive page can just hand over the selected ArchiveVersion. Progress is
//  recorded separately (Issue 17) and is keyed on the episode, not the version,
//  so switching versions keeps the same watch progress.

import Foundation
import AppKit
import OSLog

public enum LibraryPlayback {

    private static let logger = Logger(subsystem: "iina-magnet", category: "playback")

    /// Opens the version's file in iina via `bridge`. Returns false (no-op) when
    /// the file is missing or no bridge is registered.
    @MainActor
    @discardableResult
    public static func play(_ version: ArchiveVersion, using bridge: (any IinaBridge)?) -> Bool {
        guard !version.isMissing else {
            logger.notice("play skipped — file missing: \(version.fileURL.lastPathComponent, privacy: .public)")
            return false
        }
        guard let bridge else {
            logger.notice("play skipped — no IinaBridge registered")
            return false
        }
        bridge.openForPlayback(resolvedURL(for: version))
        return true
    }

    /// Reveals the version's file in Finder.
    @MainActor
    public static func revealInFinder(_ version: ArchiveVersion) {
        NSWorkspace.shared.activateFileViewerSelecting([resolvedURL(for: version)])
    }

    /// Resolves the security-scoped bookmark if present (starting access), else
    /// returns the stored URL. iina reads the file asynchronously, so we keep the
    /// scope open for the playback session rather than ending it immediately.
    private static func resolvedURL(for version: ArchiveVersion) -> URL {
        guard let data = version.bookmark else { return version.fileURL }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            return version.fileURL
        }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }
}

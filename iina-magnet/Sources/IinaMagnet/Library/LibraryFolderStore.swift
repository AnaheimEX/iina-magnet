//
//  LibraryFolderStore.swift
//  IinaMagnet
//
//  Persists the media-library root folders the user adds (Issue 20). Stored as
//  security-scoped bookmarks in UserDefaults so access survives relaunches under
//  the sandbox; falls back to a plain bookmark when the security-scoped option
//  isn't available (non-sandboxed builds). The scanner (Issue 04) is handed the
//  resolved URLs.
//
//  Access discipline: `resolveRoots()` starts security-scoped access and returns
//  a handle the caller must `release()` when done (the scan). Display strings use
//  the names captured at add-time, so the render path never resolves a bookmark
//  or starts an access (avoiding the per-render scope leak).

import Foundation
import OSLog

@MainActor
public final class LibraryFolderStore {

    public static let shared = LibraryFolderStore()
    private static let logger = Logger(subsystem: "iina-magnet", category: "library-folders")

    private let bookmarksKey = "magnet.library.folderBookmarks"
    private let namesKey = "magnet.library.folderNames"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isConfigured: Bool { !storedBookmarks().isEmpty }

    /// Folder names captured when added — cheap, never resolves a bookmark, so
    /// safe to read from a SwiftUI render path.
    public func summary() -> String {
        let names = storedNames()
        guard !names.isEmpty else { return "尚未添加媒体文件夹" }
        return "已就绪：" + names.joined(separator: "、")
    }

    /// Resolves the bookmarks, starting security-scoped access. The returned
    /// handle owns the access; call `release()` once the scan finishes. Refreshes
    /// any stale bookmark in place so a moved/renamed folder doesn't silently drop.
    public func resolveRoots() -> RootAccess {
        var urls: [URL] = []
        var bookmarks = storedBookmarks()
        var changed = false

        for i in bookmarks.indices {
            var stale = false
            guard let url = resolve(bookmarks[i], stale: &stale) else { continue }
            if stale, let refreshed = bookmark(for: url) {
                bookmarks[i] = refreshed
                changed = true
            }
            if url.startAccessingSecurityScopedResource() {
                urls.append(url)
            } else {
                // Non-sandboxed builds: bookmark resolved but no scope needed.
                urls.append(url)
            }
        }
        if changed { defaults.set(bookmarks, forKey: bookmarksKey) }
        return RootAccess(urls: urls)
    }

    /// Adds a folder, persisting a bookmark + display name. No-op if a bookmark
    /// can't be made.
    public func add(_ url: URL) {
        guard let data = bookmark(for: url) else {
            Self.logger.error("could not bookmark \(url.path, privacy: .public)")
            return
        }
        var marks = storedBookmarks(); marks.append(data); defaults.set(marks, forKey: bookmarksKey)
        var names = storedNames(); names.append(url.lastPathComponent); defaults.set(names, forKey: namesKey)
    }

    public func removeAll() {
        defaults.removeObject(forKey: bookmarksKey)
        defaults.removeObject(forKey: namesKey)
    }

    // MARK: -

    private func storedBookmarks() -> [Data] { defaults.array(forKey: bookmarksKey) as? [Data] ?? [] }
    private func storedNames() -> [String] { defaults.array(forKey: namesKey) as? [String] ?? [] }

    private func resolve(_ data: Data, stale: inout Bool) -> URL? {
        #if os(macOS)
        return try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                        relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        return try? URL(resolvingBookmarkData: data, relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
    }

    private func bookmark(for url: URL) -> Data? {
        #if os(macOS)
        if let d = try? url.bookmarkData(options: .withSecurityScope,
                                         includingResourceValuesForKeys: nil, relativeTo: nil) {
            return d
        }
        #endif
        return try? url.bookmarkData(includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

/// Owns the started security-scoped access for a set of root URLs; the caller
/// must `release()` it when the scan completes (idempotent).
public final class RootAccess {
    public let urls: [URL]
    private var released = false
    init(urls: [URL]) { self.urls = urls }

    public func release() {
        guard !released else { return }
        released = true
        for url in urls { url.stopAccessingSecurityScopedResource() }
    }
}

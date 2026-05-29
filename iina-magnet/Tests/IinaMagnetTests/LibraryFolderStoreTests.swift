//
//  LibraryFolderStoreTests.swift
//  IinaMagnetTests
//
//  Bookmark round-trip for the configured media-library root folders.

import Testing
import Foundation
@testable import IinaMagnet

@MainActor
@Suite("LibraryFolderStore", .serialized)
struct LibraryFolderStoreTests {

    private func freshStore() -> (LibraryFolderStore, UserDefaults) {
        let suite = "test.folderstore." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        return (LibraryFolderStore(defaults: defaults), defaults)
    }

    @Test("add → isConfigured, roots resolves back to the folder")
    func addResolve() throws {
        let (store, _) = freshStore()
        #expect(!store.isConfigured)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folders-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        store.add(dir)
        #expect(store.isConfigured)
        let access = store.resolveRoots()
        defer { access.release() }
        #expect(access.urls.count == 1)
        // Resolved URL points at the same directory (symlinks like /var→/private/var
        // are normalized away by comparing the last path component).
        #expect(access.urls.first?.lastPathComponent == dir.lastPathComponent)
        #expect(store.summary().contains(dir.lastPathComponent))
    }

    @Test("removeAll clears configuration")
    func removeAll() throws {
        let (store, _) = freshStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folders-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        store.add(dir)
        #expect(store.isConfigured)
        store.removeAll()
        #expect(!store.isConfigured)
        #expect(store.resolveRoots().urls.isEmpty)
    }
}

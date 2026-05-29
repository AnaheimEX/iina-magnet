//
//  LibraryScannerTests.swift
//  IinaMagnetTests
//
//  Phase 2 Issue 04: full scan over a synthetic temp tree, fingerprint dedup,
//  reconcile, and the FSEvents change coalescer. No real FSEvents (the live
//  stream is a thin wrapper; the testable logic is ChangeCoalescer).

import Testing
import Foundation
@testable import IinaMagnet

@Suite("LibraryScanner")
struct LibraryScannerTests {

    /// Builds a temp directory tree of empty files; returns the root.
    private func makeTree(_ relPaths: [String]) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("scan-" + UUID().uuidString,
                                                                 isDirectory: true)
        for rel in relPaths {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return root
    }

    @Test("Full scan finds only whitelisted video files, ignores junk")
    func fullScanFiltersExtensions() async throws {
        let root = try makeTree([
            "[喵萌奶茶屋][葬送的芙莉莲][01][1080p].mkv",
            "sub/Show.S01E02.1080p.mkv",
            "readme.txt",
            "poster.jpg",
            "movie.sample.nfo",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        var files: [ScannedFile] = []
        for await p in LibraryService.scan(roots: [root]) {
            if let f = p.file { files.append(f) }
        }

        #expect(files.count == 2)
        let exts = Set(files.map { $0.url.pathExtension })
        #expect(exts == ["mkv"])
        // Parsed payload flows through.
        let frieren = files.first { $0.url.lastPathComponent.contains("芙莉莲") }
        #expect(frieren?.parsed.episode == 1)
        #expect(frieren?.parsed.title == "葬送的芙莉莲")
    }

    @Test("Hidden files (.DS_Store) are skipped")
    func skipsHidden() async throws {
        let root = try makeTree(["real.mkv", ".DS_Store", ".hidden.mkv"])
        defer { try? FileManager.default.removeItem(at: root) }

        var names: [String] = []
        for await p in LibraryService.scan(roots: [root]) {
            if let f = p.file { names.append(f.url.lastPathComponent) }
        }
        #expect(names == ["real.mkv"])
    }

    @Test("Fingerprint is stable across repeated stats of the same file")
    func fingerprintStable() throws {
        let root = try makeTree(["a.mkv"])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("a.mkv").path
        let fp1 = LibraryService.fingerprint(path: path)
        let fp2 = LibraryService.fingerprint(path: path)
        #expect(fp1?.0 == fp2?.0)
        #expect(fp1?.0.isEmpty == false)
    }

    @Test("Fingerprint nil for a non-existent path")
    func fingerprintMissing() {
        #expect(LibraryService.fingerprint(path: "/no/such/file.mkv") == nil)
    }

    @Test("Reconcile splits new vs missing fingerprints")
    func reconcile() {
        let r = LibraryService.reconcile(known: ["a", "b"], seen: ["b", "c"])
        #expect(r.new == ["c"])
        #expect(r.missing == ["a"])
    }

    @Test("ChangeCoalescer folds changed paths to parent directories and clears")
    func coalescer() {
        var c = ChangeCoalescer()
        #expect(c.isEmpty)
        c.add("/lib/Show/ep1.mkv")
        c.add("/lib/Show/ep2.mkv")   // same dir → folds to one
        c.add("/lib/Movie/m.mkv")
        let dirs = c.flush()
        #expect(Set(dirs.map(\.path)) == ["/lib/Show", "/lib/Movie"])
        #expect(c.isEmpty)            // flush clears
    }

    @Test("scanRoots add/remove is idempotent")
    func scanRootsManagement() async {
        let svc = LibraryService()
        let u = URL(fileURLWithPath: "/lib/a")
        await svc.addScanRoot(u)
        await svc.addScanRoot(u)   // dup ignored
        #expect(await svc.scanRoots == [u])
        await svc.removeScanRoot(u)
        #expect(await svc.scanRoots.isEmpty)
    }
}

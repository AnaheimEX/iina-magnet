//
//  LibraryPlaybackTests.swift
//  IinaMagnetTests
//
//  Issue 14: archive-page playback. A fake IinaBridge asserts the right file URL
//  is opened, missing files are not playable, and version ordering defaults to
//  the highest resolution.

import Testing
import Foundation
import SwiftData
@testable import IinaMagnet

@MainActor
@Suite("LibraryPlayback")
struct LibraryPlaybackTests {

    private final class FakeBridge: IinaBridge {
        var opened: [URL] = []
        func openForPlayback(_ url: URL) { opened.append(url) }
        var currentVideoPositionSec: Double? { nil }
    }

    private func version(_ path: String, quality: String? = "1080p",
                         missing: Bool = false) -> ArchiveVersion {
        ArchiveVersion(id: path, quality: quality, releaseGroup: nil, languages: [],
                       sizeText: "1 MB", isMissing: missing,
                       fileURL: URL(fileURLWithPath: path), bookmark: nil)
    }

    @Test("play opens the version's file URL via the bridge")
    func playsCorrectURL() {
        let bridge = FakeBridge()
        let ok = LibraryPlayback.play(version("/m/ep1.mkv"), using: bridge)
        #expect(ok)
        #expect(bridge.opened == [URL(fileURLWithPath: "/m/ep1.mkv")])
    }

    @Test("a missing file is not playable")
    func missingNotPlayable() {
        let bridge = FakeBridge()
        let ok = LibraryPlayback.play(version("/m/gone.mkv", missing: true), using: bridge)
        #expect(!ok)
        #expect(bridge.opened.isEmpty)
    }

    @Test("no bridge registered → no-op")
    func noBridge() {
        #expect(!LibraryPlayback.play(version("/m/ep1.mkv"), using: nil))
    }

    @Test("versions default to highest resolution first; switching keeps the episode key")
    func versionOrdering() throws {
        let ctx = ModelContext(PersistenceController.inMemory().container)
        let t = Title(kind: .tv, titleZh: "番", matchState: .confirmed)
        let s = Season(number: 1); s.title = t; t.seasons.append(s)
        let e = Episode(number: 3, seasonNumber: 1); e.season = s; s.episodes.append(e)
        let sd = VersionFile(fileURL: URL(fileURLWithPath: "/720.mkv"), fileFingerprint: "a",
                             fileSizeBytes: 100, resolution: "720p")
        let hd = VersionFile(fileURL: URL(fileURLWithPath: "/2160.mkv"), fileFingerprint: "b",
                             fileSizeBytes: 900, resolution: "2160p")
        for v in [sd, hd] { v.episode = e; e.versions.append(v) }
        ctx.insert(t); ctx.insert(s); ctx.insert(e); ctx.insert(sd); ctx.insert(hd)

        let vm = ArchiveViewModel(t)
        let versions = try #require(vm.seasons.first?.episodes.first?.versions)
        #expect(versions.first?.quality == "2160p")   // highest resolution leads
        #expect(versions.first?.fileURL == URL(fileURLWithPath: "/2160.mkv"))
        // Both versions belong to the same (title, season, episode) — progress is
        // shared regardless of which one plays (verified in WatchProgress tests).
        #expect(vm.seasons.first?.episodes.first?.id == 3)
    }
}

//
//  ArchiveViewModelTests.swift
//  IinaMagnetTests
//
//  Title → ArchiveViewModel projection for the detail page: tv seasons/episodes
//  with per-episode watch state + versions, the movie variant, and the unmatched
//  variant (rawName + fileInfo).

import Testing
import Foundation
import SwiftData
@testable import IinaMagnet

@Suite("ArchiveViewModel", .serialized)
struct ArchiveViewModelTests {

    private func makeContext() -> ModelContext {
        ModelContext(PersistenceController.inMemory().container)
    }

    @Test("tv: seasons/episodes ordered, versions + per-episode state mapped")
    func tvVariant() throws {
        let ctx = makeContext()
        let t = Title(kind: .tv, titleZh: "葬送的芙莉莲", titleJa: "葬送のフリーレン",
                      releaseYear: 2023, matchState: .confirmed)
        t.bangumiRating = 8.9
        let s = Season(number: 1); s.title = t; t.seasons.append(s)
        for n in [2, 1] {   // inserted out of order on purpose
            let e = Episode(number: n, seasonNumber: 1, title: "第\(n)集",
                            titleOriginal: "ep\(n)", airDate: Date(timeIntervalSince1970: 0))
            e.season = s; s.episodes.append(e)
            let v = VersionFile(fileURL: URL(fileURLWithPath: "/e\(n).mkv"),
                                fileFingerprint: "f\(n)", fileSizeBytes: 1_000, resolution: "1080p")
            v.episode = e; e.versions.append(v)
            ctx.insert(e); ctx.insert(v)
        }
        // Episode 1 in progress.
        let wp = WatchProgress(title: t, seasonNumber: 1, episodeNumber: 1,
                               lastPositionSec: 300, durationSec: 1440, state: .inProgress)
        t.watchProgresses.append(wp)
        ctx.insert(t); ctx.insert(s); ctx.insert(wp)

        let vm = ArchiveViewModel(t)
        #expect(!vm.isUnmatched)
        #expect(vm.ratings.first?.source == .bangumi)
        #expect(vm.totalEpisodes == 2)
        let season = try #require(vm.seasons.first)
        #expect(season.name == "第1季")
        #expect(season.episodes.map(\.number) == [1, 2])   // sorted
        let ep1 = season.episodes[0]
        #expect(ep1.titleZh == "第1集")
        #expect(ep1.titleOriginal == "ep1")
        #expect(ep1.airDateText == "1970-01-01")
        #expect(ep1.state == .inProgress)
        #expect(abs(ep1.progress - 300.0/1440.0) < 0.0001)
        #expect(ep1.versions.first?.quality == "1080p")
        #expect(vm.bestQuality == "1080p")
    }

    @Test("cast credits map to ordered CastMember list")
    func cast() throws {
        let ctx = makeContext()
        let t = Title(kind: .tv, titleZh: "葬送的芙莉莲", matchState: .confirmed)
        let c0 = Credit(actorName: "种崎敦美", characterName: "芙莉莲", order: 0)
        let c1 = Credit(actorName: "市之濑加那", characterName: "费伦", order: 1)
        for c in [c1, c0] { c.title = t; t.credits.append(c) }   // inserted out of order
        ctx.insert(t); ctx.insert(c0); ctx.insert(c1)

        let vm = ArchiveViewModel(t)
        #expect(vm.cast.map(\.name) == ["种崎敦美", "市之濑加那"])   // sorted by order
        #expect(vm.cast.first?.role == "芙莉莲")
    }

    @Test("movie: versions surfaced directly, no season grid, runtime kept")
    func movieVariant() throws {
        let ctx = makeContext()
        let t = Title(kind: .movie, titleZh: "千与千寻", releaseYear: 2001)
        t.runtimeMinutes = 125
        let s = Season(number: 0); s.title = t; t.seasons.append(s)
        let e = Episode(number: 0, seasonNumber: 0); e.season = s; s.episodes.append(e)
        let hd = VersionFile(fileURL: URL(fileURLWithPath: "/a.mkv"), fileFingerprint: "a",
                             fileSizeBytes: 4_000_000_000, resolution: "2160p", releaseGroup: "REMUX")
        let lost = VersionFile(fileURL: URL(fileURLWithPath: "/b.mkv"), fileFingerprint: "b",
                               fileSizeBytes: 1_000, resolution: "720p")
        lost.isMissing = true
        for v in [hd, lost] { v.episode = e; e.versions.append(v) }
        ctx.insert(t); ctx.insert(s); ctx.insert(e); ctx.insert(hd); ctx.insert(lost)

        let vm = ArchiveViewModel(t)
        #expect(vm.seasons.isEmpty)
        #expect(vm.movieVersions.count == 2)
        #expect(vm.runtimeMinutes == 125)
        #expect(vm.bestQuality == "2160p")          // missing 720p excluded from best
        #expect(vm.movieVersions.contains { $0.isMissing })
    }

    @Test("unmatched: rawName + fileInfo summarize the files")
    func unmatchedVariant() throws {
        let ctx = makeContext()
        let t = Title(kind: .unknown, titleZh: "[Nekomoe] Unnamed", matchState: .unmatched)
        let s = Season(number: 0); s.title = t; t.seasons.append(s)
        let e = Episode(number: 1, seasonNumber: 0); e.season = s; s.episodes.append(e)
        let v = VersionFile(fileURL: URL(fileURLWithPath: "/Volumes/Media/_inbox/Unnamed.E01.mkv"),
                            fileFingerprint: "x", fileSizeBytes: 486_000_000, resolution: "1080p")
        v.episode = e; e.versions.append(v)
        ctx.insert(t); ctx.insert(s); ctx.insert(e); ctx.insert(v)

        let vm = ArchiveViewModel(t)
        #expect(vm.isUnmatched)
        #expect(vm.rawName == "Unnamed.E01.mkv")
        #expect(vm.seasons.first?.name == "未分季")
        let info = vm.fileInfo(from: t)
        #expect(info.fileCount == 1)
        #expect(info.folder == "/Volumes/Media/_inbox")
    }
}

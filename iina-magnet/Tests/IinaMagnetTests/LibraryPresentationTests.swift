//
//  LibraryPresentationTests.swift
//  IinaMagnetTests
//
//  Covers the presentation layer: pure formatting (size / timecode / resume
//  label) and the Title → LibraryItemViewModel mapping (ratings order, version
//  count, top quality, file totals, resume info, caption).

import Testing
import Foundation
import SwiftData
@testable import IinaMagnet

@Suite("LibraryPresentation", .serialized)
struct LibraryPresentationTests {

    // MARK: - Pure formatting

    @Test("timecode omits hours under an hour, includes them above")
    func timecode() {
        #expect(LibraryFormatting.timecode(75) == "01:15")
        #expect(LibraryFormatting.timecode(4350) == "1:12:30")
        #expect(LibraryFormatting.timecode(-5) == "00:00")
    }

    @Test("resume label: tv shows episode + remaining minutes (rounded up)")
    func resumeLabelTV() {
        let label = LibraryFormatting.resumeLabel(episodeNumber: 14,
                                                  positionSec: 780, durationSec: 1440)
        #expect(label == "续播 第14集 · 还剩 11 分钟")
        // Unknown duration → no remaining clause.
        #expect(LibraryFormatting.resumeLabel(episodeNumber: 3, positionSec: 0, durationSec: 0)
                == "续播 第3集")
    }

    @Test("resume label: movie shows absolute timecodes")
    func resumeLabelMovie() {
        let label = LibraryFormatting.resumeLabel(episodeNumber: nil,
                                                  positionSec: 4350, durationSec: 7500)
        #expect(label == "续播 · 1:12:30 / 2:05:00")
        // Sub-hour position against an hours-long film shares the duration's width.
        #expect(LibraryFormatting.resumeLabel(episodeNumber: nil, positionSec: 300, durationSec: 7500)
                == "续播 · 0:05:00 / 2:05:00")
        // Season-0 placeholder episode number is treated as a movie.
        #expect(LibraryFormatting.resumeLabel(episodeNumber: 0, positionSec: 0, durationSec: 0)
                == "续播")
    }

    @Test("progress clamps to 0...1 and is zero when duration unknown")
    func progress() {
        #expect(LibraryFormatting.progress(positionSec: 30, durationSec: 120) == 0.25)
        #expect(LibraryFormatting.progress(positionSec: 999, durationSec: 100) == 1)
        #expect(LibraryFormatting.progress(positionSec: 30, durationSec: 0) == 0)
    }

    // MARK: - Title → view model

    @Test("maps ratings in BGM→TMDB→豆瓣 order, present-only")
    func ratingsOrder() throws {
        let ctx = ModelContext(PersistenceController.inMemory().container)
        let t = Title(kind: .tv, titleZh: "葬送的芙莉莲")
        t.bangumiRating = 8.9
        t.doubanRating = 9.5         // tmdb absent
        ctx.insert(t)

        let vm = LibraryItemViewModel(t)
        #expect(vm.ratings.map(\.source) == [.bangumi, .douban])
        #expect(vm.ratings.first?.value == 8.9)
    }

    @Test("version count = max per episode; top quality = highest present resolution")
    func versionsAndQuality() throws {
        let ctx = ModelContext(PersistenceController.inMemory().container)
        let t = Title(kind: .tv, titleZh: "测试番")
        let s = Season(number: 1); s.title = t; t.seasons.append(s)
        let e = Episode(number: 1, seasonNumber: 1); e.season = s; s.episodes.append(e)

        let v1 = VersionFile(fileURL: URL(fileURLWithPath: "/a.mkv"), fileFingerprint: "1",
                             fileSizeBytes: 1_000, resolution: "1080p")
        let v2 = VersionFile(fileURL: URL(fileURLWithPath: "/b.mkv"), fileFingerprint: "2",
                             fileSizeBytes: 2_000, resolution: "2160p")
        let v3 = VersionFile(fileURL: URL(fileURLWithPath: "/c.mkv"), fileFingerprint: "3",
                             fileSizeBytes: 4_000, resolution: "720p")
        v3.isMissing = true          // missing files excluded from totals + top quality
        for v in [v1, v2, v3] { v.episode = e; e.versions.append(v) }
        ctx.insert(t); ctx.insert(s); ctx.insert(e)
        ctx.insert(v1); ctx.insert(v2); ctx.insert(v3)

        let vm = LibraryItemViewModel(t)
        #expect(vm.versionCount == 3)        // counts all versions on the episode
        #expect(vm.fileCount == 2)           // present only
        #expect(vm.totalSizeBytes == 3_000)  // 1080p + 2160p, missing excluded
        #expect(vm.topQuality == "2160p")    // highest present resolution
    }

    @Test("top quality ranks non-pixel tokens (4K/UHD) above 1080p")
    func topQualityMarketingTokens() throws {
        let ctx = ModelContext(PersistenceController.inMemory().container)
        let t = Title(kind: .movie, titleZh: "电影")
        let s = Season(number: 0); s.title = t; t.seasons.append(s)
        let e = Episode(number: 0, seasonNumber: 0); e.season = s; s.episodes.append(e)
        let hd = VersionFile(fileURL: URL(fileURLWithPath: "/hd.mkv"), fileFingerprint: "h",
                             fileSizeBytes: 1, resolution: "1080p")
        let uhd = VersionFile(fileURL: URL(fileURLWithPath: "/uhd.mkv"), fileFingerprint: "u",
                              fileSizeBytes: 1, resolution: "4K")
        for v in [hd, uhd] { v.episode = e; e.versions.append(v) }
        ctx.insert(t); ctx.insert(s); ctx.insert(e); ctx.insert(hd); ctx.insert(uhd)

        #expect(LibraryItemViewModel(t).topQuality == "4K")
    }

    @Test("resume info comes from the latest in-progress episode")
    func resume() throws {
        let ctx = ModelContext(PersistenceController.inMemory().container)
        let t = Title(kind: .tv, titleZh: "测试番")
        ctx.insert(t)

        let old = WatchProgress(title: t, seasonNumber: 1, episodeNumber: 5,
                                lastPositionSec: 60, durationSec: 1440, state: .inProgress)
        old.updatedAt = Date(timeIntervalSince1970: 1)
        let recent = WatchProgress(title: t, seasonNumber: 1, episodeNumber: 14,
                                   lastPositionSec: 780, durationSec: 1440, state: .inProgress)
        recent.updatedAt = Date(timeIntervalSince1970: 2)
        let done = WatchProgress(title: t, seasonNumber: 1, episodeNumber: 1,
                                 lastPositionSec: 1440, durationSec: 1440, state: .completed)
        for wp in [old, recent, done] { t.watchProgresses.append(wp); ctx.insert(wp) }

        let vm = LibraryItemViewModel(t)
        let resume = try #require(vm.resume)
        #expect(resume.episodeNumber == 14)              // latest in-progress, not the completed one
        #expect(resume.label == "续播 第14集 · 还剩 11 分钟")
        #expect(abs(resume.progress - 780.0/1440.0) < 0.0001)
    }

    @Test("unmatched item caption summarizes files; rawName is the file name")
    func unmatchedCaption() throws {
        let ctx = ModelContext(PersistenceController.inMemory().container)
        let t = Title(kind: .unknown, titleZh: "[Nekomoe] Unnamed")
        let s = Season(number: 0); s.title = t; t.seasons.append(s)
        let e = Episode(number: 1, seasonNumber: 0); e.season = s; s.episodes.append(e)
        let v = VersionFile(fileURL: URL(fileURLWithPath: "/inbox/Unnamed.S01E01.mkv"),
                            fileFingerprint: "x", fileSizeBytes: 486_000_000, resolution: "1080p")
        v.episode = e; e.versions.append(v)
        ctx.insert(t); ctx.insert(s); ctx.insert(e); ctx.insert(v)

        let vm = LibraryItemViewModel(t)
        #expect(vm.rawName == "Unnamed.S01E01.mkv")
        #expect(vm.caption.hasPrefix("1 个文件 · "))
        #expect(vm.ratings.isEmpty)
    }
}

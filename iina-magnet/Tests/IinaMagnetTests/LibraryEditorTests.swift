//
//  LibraryEditorTests.swift
//  IinaMagnetTests
//
//  The metadata fallback / manual-adaptation mechanism: confirm, mark-unmatched,
//  manual field edit, and re-match (re-binding to a user-picked metadata record).

import Testing
import Foundation
import SwiftData
@testable import IinaMagnet

@Suite("LibraryEditor", .serialized)
struct LibraryEditorTests {

    private func makeContext() -> ModelContext {
        ModelContext(PersistenceController.inMemory().container)
    }

    @Test("confirm flips a pending match to confirmed")
    func confirm() throws {
        let ctx = makeContext()
        let t = Title(kind: .tv, titleZh: "某番", matchState: .pendingConfirmation, matchScore: 0.72)
        ctx.insert(t)
        try LibraryEditor(context: ctx).confirm(t)
        #expect(t.matchState == .confirmed)
    }

    @Test("markUnmatched drops the title into the unmatched bucket")
    func markUnmatched() throws {
        let ctx = makeContext()
        let t = Title(kind: .tv, titleZh: "某番", matchState: .pendingConfirmation)
        ctx.insert(t)
        try LibraryEditor(context: ctx).markUnmatched(t)
        #expect(t.matchState == .unmatched)
    }

    @Test("manual edit overrides fields, trims empties, marks confirmed")
    func manualEdit() throws {
        let ctx = makeContext()
        let t = Title(kind: .unknown, titleZh: "movie.2023.2160p", matchState: .unmatched)
        ctx.insert(t)

        let edits = ManualEdits(titleZh: "你的名字。", titleJa: "  ", releaseYear: 2016, kind: .movie)
        try LibraryEditor(context: ctx).applyManual(edits, to: t)

        #expect(t.titleZh == "你的名字。")
        #expect(t.titleJa == nil)               // whitespace-only edit ignored
        #expect(t.releaseYear == 2016)
        #expect(t.kind == .movie)
        #expect(t.matchState == .confirmed)
        #expect(t.matchScore == 1)
    }

    @Test("re-match re-binds metadata, refreshes episodes + tags, confirms")
    func rematch() throws {
        let ctx = makeContext()
        // A wrongly-matched title with one episode and a stale year tag.
        let t = Title(kind: .tv, titleZh: "错的番", releaseYear: 1999,
                      matchState: .pendingConfirmation, matchScore: 0.66)
        let s = Season(number: 1); s.title = t; t.seasons.append(s)
        let e = Episode(number: 1, seasonNumber: 1, title: "旧标题"); e.season = s; s.episodes.append(e)
        ctx.insert(t); ctx.insert(s); ctx.insert(e)

        let details = MetadataDetails(
            providerId: .bangumi, externalId: "459283",
            titleZh: "葬送的芙莉莲", titleJa: "葬送のフリーレン",
            overview: "勇者一行打倒了魔王。",
            posterURL: URL(string: "https://lain.bgm.tv/pic/459283.jpg"),
            releaseYear: 2023, rating: 8.9,
            episodes: [.init(number: 1, title: "旅程的终点", titleOriginal: "旅の終わり")])

        try LibraryEditor(context: ctx).applyRematch(details, to: t)

        #expect(t.titleZh == "葬送的芙莉莲")
        #expect(t.titleJa == "葬送のフリーレン")
        #expect(t.bangumiId == 459283)
        #expect(t.bangumiRating == 8.9)
        #expect(t.releaseYear == 2023)
        #expect(t.matchState == .confirmed)
        #expect(t.matchScore == 1)
        #expect(e.title == "旅程的终点")            // episode metadata refreshed
        #expect(e.titleOriginal == "旅の終わり")
        // New year tag attached.
        #expect(t.tags.contains { $0.name == "2023" && $0.category == .year })
    }

    @Test("re-match replaces cast; a cast-less source leaves existing cast intact")
    func rematchCast() throws {
        let ctx = makeContext()
        let t = Title(kind: .tv, titleZh: "番", matchState: .pendingConfirmation)
        ctx.insert(t)

        // First re-match brings cast.
        let withCast = MetadataDetails(providerId: .bangumi, externalId: "1",
                                       cast: [.init(actor: "种崎敦美", character: "芙莉莲")])
        try LibraryEditor(context: ctx).applyRematch(withCast, to: t)
        #expect(t.credits.count == 1)
        #expect(t.credits.first?.actorName == "种崎敦美")

        // A later re-match to a cast-less source must not wipe the existing cast.
        let noCast = MetadataDetails(providerId: .bangumi, externalId: "2")
        try LibraryEditor(context: ctx).applyRematch(noCast, to: t)
        #expect(t.credits.count == 1)

        // A re-match with new cast replaces (no duplicates).
        let newCast = MetadataDetails(providerId: .bangumi, externalId: "3",
                                      cast: [.init(actor: "A", character: "a"),
                                             .init(actor: "B", character: "b")])
        try LibraryEditor(context: ctx).applyRematch(newCast, to: t)
        #expect(t.credits.count == 2)
        #expect(Set(t.credits.map(\.actorName)) == ["A", "B"])
    }

    @Test("re-match does not clobber existing fields with nil from the new source")
    func rematchKeepsExisting() throws {
        let ctx = makeContext()
        let t = Title(kind: .movie, titleZh: "千与千寻", titleJa: "千と千尋の神隠し", releaseYear: 2001)
        t.runtimeMinutes = 125
        ctx.insert(t)

        // Sparse details: only a rating, everything else nil.
        let details = MetadataDetails(providerId: .douban, externalId: "1291561", rating: 9.4)
        try LibraryEditor(context: ctx).applyRematch(details, to: t)

        #expect(t.titleZh == "千与千寻")          // preserved
        #expect(t.runtimeMinutes == 125)          // preserved
        #expect(t.doubanRating == 9.4)            // new rating stored under its source
        #expect(t.bangumiRating == nil)
    }

    @Test("rebind migrates the placeholder's files onto the existing Title, deletes placeholder")
    func rebindMigratesFiles() throws {
        let ctx = makeContext()

        // An existing, confirmed Title for bangumi 459283 with one episode.
        let target = Title(kind: .tv, titleZh: "葬送的芙莉莲", matchState: .confirmed)
        target.bangumiId = 459283
        let ts = Season(number: 1); ts.title = target; target.seasons.append(ts)
        let te = Episode(number: 1, seasonNumber: 1); te.season = ts; ts.episodes.append(te)
        ctx.insert(target); ctx.insert(ts); ctx.insert(te)

        // A placeholder created from an unmatched scan, holding the actual file.
        let placeholder = Title(kind: .unknown, titleZh: "[ANi] Sousou", matchState: .unmatched)
        let ps = Season(number: 1); ps.title = placeholder; placeholder.seasons.append(ps)
        let pe = Episode(number: 1, seasonNumber: 1); pe.season = ps; ps.episodes.append(pe)
        let file = VersionFile(fileURL: URL(fileURLWithPath: "/m/Sousou.E01.mkv"),
                               fileFingerprint: "fp1", fileSizeBytes: 1_000, resolution: "1080p")
        file.episode = pe; pe.versions.append(file)
        // Progress recorded against the placeholder before confirmation.
        let wp = WatchProgress(title: placeholder, seasonNumber: 1, episodeNumber: 1,
                               lastPositionSec: 300, durationSec: 1440, state: .inProgress)
        placeholder.watchProgresses.append(wp)
        ctx.insert(placeholder); ctx.insert(ps); ctx.insert(pe); ctx.insert(file); ctx.insert(wp)

        let details = MetadataDetails(providerId: .bangumi, externalId: "459283",
                                      titleZh: "葬送的芙莉莲", releaseYear: 2023)
        let survivor = try LibraryEditor(context: ctx).rebind(placeholder, to: details)
        try ctx.save()

        #expect(survivor.persistentModelID == target.persistentModelID)   // merged into existing
        // The file survived and now hangs off the target's episode.
        let files = try ctx.fetch(FetchDescriptor<VersionFile>())
        #expect(files.count == 1)
        #expect(files.first?.episode?.season?.title?.bangumiId == 459283)
        // Placeholder is gone — only one Title remains.
        #expect(try ctx.fetch(FetchDescriptor<Title>()).count == 1)
        // Watch progress was re-keyed to the survivor, not cascade-deleted.
        let progress = try ctx.fetch(FetchDescriptor<WatchProgress>())
        #expect(progress.count == 1)
        #expect(progress.first?.title?.bangumiId == 459283)
    }

    @Test("rebind with no existing match applies in place (no merge)")
    func rebindInPlace() throws {
        let ctx = makeContext()
        let t = Title(kind: .unknown, titleZh: "未知", matchState: .unmatched)
        ctx.insert(t)
        let details = MetadataDetails(providerId: .bangumi, externalId: "999", titleZh: "孤独摇滚")
        let survivor = try LibraryEditor(context: ctx).rebind(t, to: details)
        #expect(survivor.persistentModelID == t.persistentModelID)
        #expect(t.titleZh == "孤独摇滚")
        #expect(t.matchState == .confirmed)
        #expect(try ctx.fetch(FetchDescriptor<Title>()).count == 1)
    }

    @Test("re-match prunes stale source-derived tags but keeps file/user tags")
    func rebindPrunesStaleTags() throws {
        let ctx = makeContext()
        let t = Title(kind: .tv, titleZh: "番", releaseYear: 1999,
                      matchState: .pendingConfirmation)
        // Old derived tags + a file-derived quality tag + a user tag.
        let oldYear = Tag(name: "1999", category: .year)
        let oldGenre = Tag(name: "战争", category: .genre)
        let quality = Tag(name: "1080p", category: .quality)
        let userTag = Tag(name: "我的最爱", category: .userDefined)
        [oldYear, oldGenre, quality, userTag].forEach(ctx.insert)
        t.tags.append(contentsOf: [oldYear, oldGenre, quality, userTag])
        ctx.insert(t)

        let details = MetadataDetails(providerId: .bangumi, externalId: "459283",
                                      titleZh: "葬送的芙莉莲", releaseYear: 2023,
                                      genres: ["奇幻"])
        try LibraryEditor(context: ctx).applyRematch(details, to: t)

        let names = Set(t.tags.map(\.name))
        #expect(!names.contains("1999"))      // stale year pruned
        #expect(!names.contains("战争"))       // stale genre pruned
        #expect(names.contains("2023"))       // new year
        #expect(names.contains("奇幻"))        // new genre
        #expect(names.contains("1080p"))      // file-derived quality kept
        #expect(names.contains("我的最爱"))    // user tag kept
    }

    @Test("pendingTitles returns only non-confirmed titles")
    func pendingQueue() throws {
        let ctx = makeContext()
        let confirmed = Title(kind: .tv, titleZh: "已确认", matchState: .confirmed)
        let pending = Title(kind: .tv, titleZh: "待确认", matchState: .pendingConfirmation)
        let unmatched = Title(kind: .unknown, titleZh: "未匹配", matchState: .unmatched)
        [confirmed, pending, unmatched].forEach(ctx.insert)
        try ctx.save()

        let queue = try LibraryEditor(context: ctx).pendingTitles()
        #expect(queue.count == 2)
        #expect(!queue.contains { $0.matchState == .confirmed })
    }
}

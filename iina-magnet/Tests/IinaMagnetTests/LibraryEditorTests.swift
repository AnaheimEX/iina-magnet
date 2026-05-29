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
}

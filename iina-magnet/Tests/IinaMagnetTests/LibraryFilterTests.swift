//
//  LibraryFilterTests.swift
//  IinaMagnetTests
//
//  Pure filter + sort engine: section / tags(AND) / query / sort, mirroring the
//  handoff design's App.jsx semantics.

import Testing
import Foundation
import SwiftData
@testable import IinaMagnet

@Suite("LibraryFilter", .serialized)
struct LibraryFilterTests {

    /// Shared store so each built Title gets a distinct persistentModelID.
    private let ctx = ModelContext(PersistenceController.inMemory().container)

    private func item(_ titleZh: String,
                      kind: MediaKind = .tv,
                      year: Int? = 2023,
                      state: ProgressState = .unseen,
                      match: MatchState = .confirmed,
                      bgm: Double? = nil,
                      tags: [String] = [],
                      original: String? = nil,
                      addedDaysAgo: Double = 0) -> LibraryItemViewModel {
        let t = Title(kind: kind, titleZh: titleZh, releaseYear: year, matchState: match)
        t.titleJa = original
        t.bangumiRating = bgm
        t.aggregateState = state
        t.createdAt = Date(timeIntervalSinceNow: -addedDaysAgo * 86_400)
        for name in tags {
            let tag = Tag(name: name, category: .genre)
            ctx.insert(tag)
            t.tags.append(tag)
        }
        ctx.insert(t)
        return LibraryItemViewModel(t)
    }

    @Test("kind section keeps only that media kind")
    func sectionKind() {
        let items = [item("番A", kind: .tv), item("片B", kind: .movie), item("番C", kind: .tv)]
        let out = LibraryFilterEngine.apply(section: .kind(.tv), to: items)
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.kind == .tv })
    }

    @Test("state + match sections filter on the aggregate/match dimension")
    func sectionStateMatch() {
        let items = [item("A", state: .inProgress), item("B", state: .completed),
                     item("C", state: .inProgress, match: .pendingConfirmation)]
        #expect(LibraryFilterEngine.apply(section: .state(.inProgress), to: items).count == 2)
        #expect(LibraryFilterEngine.apply(section: .match(.pendingConfirmation), to: items).count == 1)
    }

    @Test("tags combine with AND")
    func tagsAnd() {
        let items = [
            item("A", tags: ["奇幻", "2023", "日本"]),
            item("B", tags: ["奇幻", "2022"]),
            item("C", tags: ["奇幻", "2023"]),
        ]
        let out = LibraryFilterEngine.apply(section: .all, tags: ["奇幻", "2023"], to: items)
        #expect(Set(out.map(\.titleZh)) == ["A", "C"])
    }

    @Test("query matches title, original, and is case-insensitive")
    func query() {
        let items = [item("孤独摇滚", original: "Bocchi the Rock"), item("间谍过家家")]
        #expect(LibraryFilterEngine.apply(section: .all, query: "bocchi", to: items).count == 1)
        #expect(LibraryFilterEngine.apply(section: .all, query: "摇滚", to: items).count == 1)
        #expect(LibraryFilterEngine.apply(section: .all, query: "zzz", to: items).isEmpty)
    }

    @Test("recent section caps to the newest N by addedAt")
    func recent() {
        let items = (0..<20).map { item("作品\($0)", addedDaysAgo: Double($0)) }
        let out = LibraryFilterEngine.apply(section: .recent, sort: .recent, recentLimit: 5, to: items)
        #expect(out.count == 5)
        #expect(out.first?.titleZh == "作品0")   // newest (0 days ago) first
        #expect(out.last?.titleZh == "作品4")
    }

    @Test("sort: year desc, rating desc, state order (在看→未看→已看)")
    func sorts() {
        let items = [
            item("老", year: 2001, state: .completed, bgm: 7.0),
            item("新", year: 2023, state: .inProgress, bgm: 9.0),
            item("中", year: 2018, state: .unseen, bgm: 8.0),
        ]
        #expect(LibraryFilterEngine.apply(section: .all, sort: .year, to: items).map(\.titleZh)
                == ["新", "中", "老"])
        #expect(LibraryFilterEngine.apply(section: .all, sort: .rating, to: items).map(\.titleZh)
                == ["新", "中", "老"])
        #expect(LibraryFilterEngine.apply(section: .all, sort: .state, to: items).map(\.titleZh)
                == ["新", "中", "老"])   // inProgress, unseen, completed
    }

    @Test("sort: title uses localized ascending compare")
    func sortTitle() {
        let items = [item("Cat"), item("Apple"), item("banana")]
        let out = LibraryFilterEngine.apply(section: .all, sort: .title, to: items)
        #expect(out.map(\.titleZh) == ["Apple", "banana", "Cat"])  // case-insensitive localized
    }
}

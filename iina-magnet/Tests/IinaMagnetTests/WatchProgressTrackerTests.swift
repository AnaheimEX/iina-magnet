//
//  WatchProgressTrackerTests.swift
//  IinaMagnetTests
//
//  Issue 17: WatchProgressWriter (reverse-lookup + upsert + aggregate tri-state)
//  and WatchProgressTracker (debounce). No iina dependency — samples are injected.

import Testing
import Foundation
import SwiftData
@testable import IinaMagnet

@Suite("WatchProgress", .serialized)
struct WatchProgressTrackerTests {

    /// Builds a tv Title with `episodeCount` episodes in season 1, each with one
    /// version file at /e<n>.mkv. Returns the context + title.
    private func makeShow(episodeCount: Int, ctx: ModelContext,
                          kind: MediaKind = .tv) -> Title {
        let t = Title(kind: kind, titleZh: "测试番", matchState: .confirmed)
        let s = Season(number: 1); s.title = t; t.seasons.append(s)
        ctx.insert(t); ctx.insert(s)
        for n in 1...episodeCount {
            let e = Episode(number: n, seasonNumber: 1); e.season = s; s.episodes.append(e)
            let v = VersionFile(fileURL: URL(fileURLWithPath: "/e\(n).mkv"),
                                fileFingerprint: "fp\(n)", fileSizeBytes: 1, resolution: "1080p")
            v.episode = e; e.versions.append(v)
            ctx.insert(e); ctx.insert(v)
        }
        return t
    }

    private func makeContext() -> ModelContext {
        ModelContext(PersistenceController.inMemory().container)
    }

    @Test("playing to 95% marks the episode completed")
    func completesAtThreshold() throws {
        let ctx = makeContext()
        _ = makeShow(episodeCount: 1, ctx: ctx)
        let title = try WatchProgressWriter(context: ctx)
            .record(url: URL(fileURLWithPath: "/e1.mkv"), positionSec: 95, durationSec: 100, ended: false)
        let wp = try #require(title?.watchProgresses.first)
        #expect(wp.state == .completed)
    }

    @Test("quitting at 40% records inProgress + position")
    func inProgressMidway() throws {
        let ctx = makeContext()
        _ = makeShow(episodeCount: 2, ctx: ctx)
        let title = try WatchProgressWriter(context: ctx)
            .record(url: URL(fileURLWithPath: "/e1.mkv"), positionSec: 40, durationSec: 100, ended: false)
        let wp = try #require(title?.watchProgresses.first)
        #expect(wp.state == .inProgress)
        #expect(wp.lastPositionSec == 40)
        #expect(title?.aggregateState == .inProgress)   // some-but-not-all started
    }

    @Test("EOF completes even below the ratio threshold")
    func endedCompletes() throws {
        let ctx = makeContext()
        _ = makeShow(episodeCount: 1, ctx: ctx)
        let title = try WatchProgressWriter(context: ctx)
            .record(url: URL(fileURLWithPath: "/e1.mkv"), positionSec: 5, durationSec: 100, ended: true)
        #expect(title?.watchProgresses.first?.state == .completed)
    }

    @Test("finishing the last episode flips the Title aggregate to 已看")
    func aggregateCompleted() throws {
        let ctx = makeContext()
        _ = makeShow(episodeCount: 2, ctx: ctx)
        let writer = WatchProgressWriter(context: ctx)

        let afterE1 = try writer.record(url: URL(fileURLWithPath: "/e1.mkv"),
                                        positionSec: 100, durationSec: 100, ended: true)
        #expect(afterE1?.aggregateState == .inProgress)   // one of two done

        let afterE2 = try writer.record(url: URL(fileURLWithPath: "/e2.mkv"),
                                        positionSec: 100, durationSec: 100, ended: true)
        #expect(afterE2?.aggregateState == .completed)    // all episodes done → 已看
    }

    @Test("progress is shared across an episode's versions")
    func crossVersionShared() throws {
        let ctx = makeContext()
        let t = makeShow(episodeCount: 1, ctx: ctx)
        // Add a second version of episode 1 at /e1-v2.mkv.
        let ep = try #require(t.seasons.first?.episodes.first)
        let v2 = VersionFile(fileURL: URL(fileURLWithPath: "/e1-v2.mkv"),
                             fileFingerprint: "fp1b", fileSizeBytes: 1, resolution: "2160p")
        v2.episode = ep; ep.versions.append(v2); ctx.insert(v2)

        let writer = WatchProgressWriter(context: ctx)
        _ = try writer.record(url: URL(fileURLWithPath: "/e1.mkv"), positionSec: 50, durationSec: 100, ended: false)
        _ = try writer.record(url: URL(fileURLWithPath: "/e1-v2.mkv"), positionSec: 95, durationSec: 100, ended: false)

        // One shared progress row, reflecting the latest (completed) sample.
        let rows = try ctx.fetch(FetchDescriptor<WatchProgress>())
        #expect(rows.count == 1)
        #expect(rows.first?.state == .completed)
    }

    @Test("unknown URL is ignored (no progress row)")
    func unknownURL() throws {
        let ctx = makeContext()
        _ = makeShow(episodeCount: 1, ctx: ctx)
        let title = try WatchProgressWriter(context: ctx)
            .record(url: URL(fileURLWithPath: "/not-in-library.mkv"), positionSec: 50, durationSec: 100, ended: false)
        #expect(title == nil)
        #expect(try ctx.fetch(FetchDescriptor<WatchProgress>()).isEmpty)
    }

    @Test("tracker debounces frequent samples; seeks and EOF always write")
    func trackerDebounce() async {
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        let tracker = WatchProgressTracker(minInterval: 5, minPositionDelta: 30) { _, _, _, _ in
            counter.n += 1
        }
        let url = URL(fileURLWithPath: "/e1.mkv")
        let t0 = Date(timeIntervalSince1970: 0)

        await tracker.ingest(url: url, positionSec: 10, durationSec: 100, ended: false, now: t0)              // write 1
        await tracker.ingest(url: url, positionSec: 12, durationSec: 100, ended: false, now: t0.addingTimeInterval(2)) // skip
        await tracker.ingest(url: url, positionSec: 50, durationSec: 100, ended: false, now: t0.addingTimeInterval(3)) // seek → write 2
        await tracker.ingest(url: url, positionSec: 99, durationSec: 100, ended: true,  now: t0.addingTimeInterval(4)) // EOF → write 3

        await MainActor.run { #expect(counter.n == 3) }
    }

    @Test("tracker writes EOF once; a player parked at the end doesn't re-write")
    func trackerEOFOnce() async {
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        let tracker = WatchProgressTracker(minInterval: 5, minPositionDelta: 30) { _, _, _, _ in
            counter.n += 1
        }
        let url = URL(fileURLWithPath: "/e1.mkv")
        let t0 = Date(timeIntervalSince1970: 0)

        await tracker.ingest(url: url, positionSec: 99, durationSec: 100, ended: true, now: t0)               // write 1
        await tracker.ingest(url: url, positionSec: 99, durationSec: 100, ended: true, now: t0.addingTimeInterval(5))  // parked → skip
        await tracker.ingest(url: url, positionSec: 99, durationSec: 100, ended: true, now: t0.addingTimeInterval(10)) // parked → skip

        await MainActor.run { #expect(counter.n == 1) }
    }
}

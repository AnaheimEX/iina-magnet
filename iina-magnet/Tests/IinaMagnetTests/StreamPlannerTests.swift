//
//  StreamPlannerTests.swift
//  IinaMagnetTests
//
//  Unit tests for the pure-function StreamPlanner. Covers boundary conditions
//  documented in Issue 07.

import Testing
import Foundation
@testable import IinaMagnet

@Suite("StreamPlanner")
struct StreamPlannerTests {

    // 2 MB pieces, 1 GB file, all pieces missing — easy math.
    private let pieceLen = 2 * 1024 * 1024
    private let totalPieces = 512
    private let bitrate = 2 * 1024 * 1024   // 2 MB/s

    private func map(downloaded: Set<Int> = []) -> PieceMap {
        PieceMap(pieceLength: pieceLen, totalPieces: totalPieces, downloaded: downloaded)
    }

    private var windows: PlannerWindows {
        PlannerWindows(urgentSeconds: 30, nearSeconds: 60, farSeconds: 120, bitrateBytesPerSec: bitrate)
    }

    @Test("Empty piece map returns no deadlines")
    func emptyPieceMap() {
        let plan = StreamPlanner.plan(
            playerOffsetBytes: 0,
            videoFileSizeBytes: 0,
            videoFileStartOffsetInTorrent: 0,
            pieceMap: PieceMap(pieceLength: 0, totalPieces: 0)
        )
        #expect(plan.isEmpty)
    }

    @Test("From file start: urgent window contains the leading pieces with deadline 0")
    func urgentFromStart() {
        let plan = StreamPlanner.plan(
            playerOffsetBytes: 0,
            videoFileSizeBytes: Int64(totalPieces) * Int64(pieceLen),
            videoFileStartOffsetInTorrent: 0,
            pieceMap: map(),
            windows: windows
        )
        // urgentSeconds=30, bitrate=2MB/s → 60 MB ahead → 30 pieces at 2MB each.
        let urgent = plan.filter { $0.deadlineMs == 0 }
        #expect(urgent.count == 30)
        #expect(urgent.first?.piece == 0)
        #expect(urgent.last?.piece == 29)
    }

    @Test("Far window is bounded by file end")
    func farBoundedByFileEnd() {
        // Tiny file: only 5 pieces total — far window can't extend past piece 4.
        let smallTotal = 5
        let smallMap = PieceMap(pieceLength: pieceLen, totalPieces: smallTotal)

        let plan = StreamPlanner.plan(
            playerOffsetBytes: 0,
            videoFileSizeBytes: Int64(smallTotal) * Int64(pieceLen),
            videoFileStartOffsetInTorrent: 0,
            pieceMap: smallMap,
            windows: windows
        )
        let maxPiece = plan.map(\.piece).max() ?? -1
        #expect(maxPiece <= smallTotal - 1)
    }

    @Test("Already-downloaded pieces are skipped")
    func skipDownloaded() {
        let downloaded: Set<Int> = [0, 1, 2, 3, 4]
        let plan = StreamPlanner.plan(
            playerOffsetBytes: 0,
            videoFileSizeBytes: Int64(totalPieces) * Int64(pieceLen),
            videoFileStartOffsetInTorrent: 0,
            pieceMap: map(downloaded: downloaded),
            windows: windows
        )
        for d in downloaded {
            #expect(!plan.contains { $0.piece == d })
        }
    }

    @Test("Player offset past mid-file: planning starts from that piece")
    func midFileOffset() {
        let offsetPieces = 100   // start at piece 100
        let plan = StreamPlanner.plan(
            playerOffsetBytes: Int64(offsetPieces * pieceLen),
            videoFileSizeBytes: Int64(totalPieces) * Int64(pieceLen),
            videoFileStartOffsetInTorrent: 0,
            pieceMap: map(),
            windows: windows
        )
        let first = plan.map(\.piece).min() ?? -1
        #expect(first >= offsetPieces)
    }

    @Test("Video file is offset inside a multi-file torrent")
    func multiFileOffset() {
        // Video file sits at offset 100 pieces into the torrent.
        let videoOffset = Int64(100 * pieceLen)
        let plan = StreamPlanner.plan(
            playerOffsetBytes: 0,
            videoFileSizeBytes: Int64(60 * pieceLen),
            videoFileStartOffsetInTorrent: videoOffset,
            pieceMap: map(),
            windows: windows
        )
        let first = plan.map(\.piece).min() ?? -1
        #expect(first == 100)  // urgent should start at the first piece of the video file
    }

    @Test("Tiered deadlines: urgent (0ms) → near (1000ms) → far (5000ms)")
    func tieredDeadlines() {
        let plan = StreamPlanner.plan(
            playerOffsetBytes: 0,
            videoFileSizeBytes: Int64(totalPieces) * Int64(pieceLen),
            videoFileStartOffsetInTorrent: 0,
            pieceMap: map(),
            windows: windows
        )
        let urgent = plan.filter { $0.deadlineMs == 0 }
        let near   = plan.filter { $0.deadlineMs == 1000 }
        let far    = plan.filter { $0.deadlineMs == 5000 }
        #expect(urgent.count == 30)   // 30s × 2MB/s ÷ 2MB
        #expect(near.count == 60)     // 60s
        #expect(far.count == 120)     // 120s
        // No piece appears in two tiers.
        let allPieces = plan.map(\.piece)
        #expect(Set(allPieces).count == allPieces.count)
    }

    @Test("Performance: 10 000 piece map computes in well under 5 ms")
    func performance() {
        let bigPieces = 10_000
        let bigMap = PieceMap(pieceLength: pieceLen, totalPieces: bigPieces)
        let t0 = Date()
        for _ in 0..<100 {
            _ = StreamPlanner.plan(
                playerOffsetBytes: Int64(5000 * pieceLen),
                videoFileSizeBytes: Int64(bigPieces) * Int64(pieceLen),
                videoFileStartOffsetInTorrent: 0,
                pieceMap: bigMap,
                windows: windows
            )
        }
        let elapsedMs = Date().timeIntervalSince(t0) * 1000
        // Should be much faster than 500 ms for 100 iterations.
        #expect(elapsedMs < 500)
    }
}

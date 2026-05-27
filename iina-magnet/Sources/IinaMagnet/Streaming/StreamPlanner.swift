//
//  StreamPlanner.swift
//  IinaMagnet
//
//  Pure-function deep module (Issue 07). Translates the player's current
//  byte offset + buffer windows + piece map into a list of piece deadlines
//  to feed libtorrent's `set_piece_deadline`.
//
//  No IO, no side effects, no actor isolation — easy to test exhaustively.

import Foundation

public struct PieceMap: Sendable, Equatable {
    public let pieceLength: Int           // bytes per piece
    public let totalPieces: Int           // covers the entire torrent
    public let downloaded: Set<Int>       // indices of already-completed pieces

    public init(pieceLength: Int, totalPieces: Int, downloaded: Set<Int> = []) {
        self.pieceLength = pieceLength
        self.totalPieces = totalPieces
        self.downloaded = downloaded
    }
}

public struct PieceDeadline: Sendable, Equatable {
    public let piece: Int
    public let deadlineMs: Int
}

public struct PlannerWindows: Sendable, Equatable {
    /// Seconds of playback that should be ready ASAP.
    public var urgentSeconds: Int
    /// After urgent — should download "soon".
    public var nearSeconds: Int
    /// After near — should download "eventually within the playback horizon".
    public var farSeconds: Int
    /// Estimated bitrate in bytes/sec; used to translate seconds → bytes → pieces.
    public var bitrateBytesPerSec: Int

    public static let `default` = PlannerWindows(
        urgentSeconds: 30,
        nearSeconds: 60,
        farSeconds: 120,
        bitrateBytesPerSec: 2 * 1024 * 1024     // 2 MB/s ≈ 16 Mbps; reasonable for 1080p H.264
    )

    public init(urgentSeconds: Int, nearSeconds: Int, farSeconds: Int, bitrateBytesPerSec: Int) {
        self.urgentSeconds = urgentSeconds
        self.nearSeconds = nearSeconds
        self.farSeconds = farSeconds
        self.bitrateBytesPerSec = bitrateBytesPerSec
    }
}

public enum StreamPlanner {

    /// Compute deadlines for the streaming horizon ahead of the current player offset.
    ///
    /// - playerOffsetBytes: cursor into the video file (not into the torrent)
    /// - videoFileSizeBytes: total size of the video file being played
    /// - videoFileStartOffsetInTorrent: byte offset of the video file inside the torrent
    /// - pieceMap: current piece map of the entire torrent
    /// - windows: deadline windows
    ///
    /// Already-downloaded pieces are omitted. Pieces past the file end are omitted.
    /// Returned deadlines: 0 ms (urgent), 1000 ms (near), 5000 ms (far).
    public static func plan(
        playerOffsetBytes: Int64,
        videoFileSizeBytes: Int64,
        videoFileStartOffsetInTorrent: Int64,
        pieceMap: PieceMap,
        windows: PlannerWindows = .default
    ) -> [PieceDeadline] {
        guard pieceMap.pieceLength > 0, pieceMap.totalPieces > 0 else { return [] }
        let clampedOffset = max(0, min(playerOffsetBytes, videoFileSizeBytes))

        let absStart = videoFileStartOffsetInTorrent + clampedOffset
        let absEnd   = videoFileStartOffsetInTorrent + videoFileSizeBytes  // exclusive

        let firstPiece = Int(absStart / Int64(pieceMap.pieceLength))
        let lastPieceExclusive = Int(((absEnd - 1) / Int64(pieceMap.pieceLength)) + 1)

        // Translate seconds → bytes → pieces for each band.
        let urgentBytes = Int64(windows.urgentSeconds) * Int64(windows.bitrateBytesPerSec)
        let nearBytes   = Int64(windows.nearSeconds)   * Int64(windows.bitrateBytesPerSec)
        let farBytes    = Int64(windows.farSeconds)    * Int64(windows.bitrateBytesPerSec)

        let urgentEnd = pieceIndex(forByte: absStart + urgentBytes, pieceLength: pieceMap.pieceLength)
        let nearEnd   = pieceIndex(forByte: absStart + urgentBytes + nearBytes, pieceLength: pieceMap.pieceLength)
        let farEnd    = pieceIndex(forByte: absStart + urgentBytes + nearBytes + farBytes, pieceLength: pieceMap.pieceLength)

        var deadlines: [PieceDeadline] = []

        for piece in firstPiece..<min(lastPieceExclusive, pieceMap.totalPieces) {
            if pieceMap.downloaded.contains(piece) { continue }

            let ms: Int
            if piece < urgentEnd {
                ms = 0
            } else if piece < nearEnd {
                ms = 1_000
            } else if piece < farEnd {
                ms = 5_000
            } else {
                continue   // outside the planning horizon
            }
            deadlines.append(PieceDeadline(piece: piece, deadlineMs: ms))
        }
        return deadlines
    }

    /// Returns the exclusive piece index for a byte offset: pieces [0, result) cover [0, byteOffset).
    private static func pieceIndex(forByte byteOffset: Int64, pieceLength: Int) -> Int {
        Int(byteOffset / Int64(pieceLength))
    }
}

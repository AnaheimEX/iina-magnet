//
//  TorrentEvent.swift
//  IinaMagnet
//
//  Public, Sendable event type emitted by TorrentManager.events.
//  Phase 1 consumers: StreamCoordinator (Issue 08), CompletionPipeline (Issue 17),
//  RSS scheduler (Issue 13 — to surface "download started" feedback).

import Foundation

public struct InfoHash: Hashable, Sendable, Codable {
    public let hex: String
    public init(_ hex: String) { self.hex = hex.lowercased() }
}

public enum TorrentEvent: Sendable {
    case metadataReceived(InfoHash)
    case pieceFinished(InfoHash, pieceIndex: Int)
    case fileCompleted(InfoHash, fileIndex: Int)
    case torrentFinished(InfoHash)
    case torrentError(InfoHash, message: String)
    case saveResumeData(InfoHash)
}

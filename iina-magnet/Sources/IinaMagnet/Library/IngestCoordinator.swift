//
//  IngestCoordinator.swift
//  IinaMagnet
//
//  Ties the Phase 2 pipeline together: scan roots → resolve metadata → ingest.
//  Reusable by the Library UI and (later, Issue 20) the startup migration.
//
//  Concurrency: scanning is off-actor and metadata resolution is async, but the
//  SwiftData ModelContext is only touched in a synchronous ingest pass with no
//  suspension points — resolve happens first into an array, then ingest runs
//  without awaits. Use one IngestCoordinator from a single isolation domain
//  (its ModelContext is not Sendable).

import Foundation
import SwiftData
import OSLog

public struct IngestCoordinator {

    private static let logger = Logger(subsystem: "iina-magnet", category: "ingest")

    private let service: MetadataService
    private let context: ModelContextBox

    /// `ModelContext` isn't Sendable; box it so the struct stays simple while we
    /// keep all context use inside the synchronous ingest pass.
    public init(service: MetadataService, context: ModelContextBox) {
        self.service = service
        self.context = context
    }

    /// Runs the full pipeline over `roots`. Returns the number of files ingested.
    /// `onProgress` is called for every scan tick (for a progress bar).
    @discardableResult
    public func run(roots: [URL],
                    onProgress: ((ScanProgress) -> Void)? = nil) async throws -> Int {
        // 1. Scan (off-actor) — collect candidates.
        var files: [ScannedFile] = []
        for await p in LibraryService.scan(roots: roots) {
            onProgress?(p)
            if let f = p.file { files.append(f) }
        }

        // 2. Resolve metadata for each (async network) — no context touched here.
        var resolved: [(ScannedFile, MetadataResolution)] = []
        resolved.reserveCapacity(files.count)
        for f in files {
            resolved.append((f, await service.resolve(f.parsed)))
        }

        // 3. Ingest (synchronous, no suspension) — the only place the context is used.
        let ingester = Ingester(context: context.context)
        var count = 0
        for (file, resolution) in resolved {
            do {
                _ = try ingester.ingest(file, resolution: resolution)
                count += 1
            } catch {
                Self.logger.error("ingest failed for \(file.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        Self.logger.info("ingested \(count)/\(files.count) file(s)")
        return count
    }
}

/// Thin non-Sendable holder so `IngestCoordinator` can carry a ModelContext
/// without pretending it is Sendable.
public final class ModelContextBox {
    public let context: ModelContext
    public init(_ context: ModelContext) { self.context = context }
}

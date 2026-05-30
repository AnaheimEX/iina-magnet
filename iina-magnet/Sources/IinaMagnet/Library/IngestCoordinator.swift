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
    private let maxConcurrentResolves: Int

    /// `ModelContext` isn't Sendable; box it so the struct stays simple while we
    /// keep all context use inside the synchronous ingest pass.
    /// - Parameter maxConcurrentResolves: in-flight metadata lookups cap (politeness
    ///   toward the provider + bounded memory); 5 is a good default for Bangumi.
    public init(service: MetadataService, context: ModelContextBox,
                maxConcurrentResolves: Int = 5) {
        self.service = service
        self.context = context
        self.maxConcurrentResolves = max(1, maxConcurrentResolves)
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

        // 2. Resolve metadata (async network) — no context touched here. Run up to
        //    `maxConcurrentResolves` lookups in flight; results are gathered by
        //    index so file↔resolution pairing stays correct regardless of order.
        let service = self.service
        var resolved = [MetadataResolution?](repeating: nil, count: files.count)
        await withTaskGroup(of: (Int, MetadataResolution).self) { group in
            var next = 0
            func submit(_ i: Int) {
                let parsed = files[i].parsed
                group.addTask { (i, await service.resolve(parsed)) }
            }
            while next < min(maxConcurrentResolves, files.count) { submit(next); next += 1 }
            while let (i, res) = await group.next() {
                resolved[i] = res
                if next < files.count { submit(next); next += 1 }
            }
        }

        // 3. Ingest (synchronous, no suspension) — the only place the context is used.
        let ingester = Ingester(context: context.context)
        var count = 0
        for (i, file) in files.enumerated() {
            guard let resolution = resolved[i] else { continue }
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

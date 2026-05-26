//
//  PersistenceController.swift
//  IinaMagnet
//
//  Owns the SwiftData ModelContainer for the entire iina-magnet feature set.
//  Phase 0 baseline: empty schema; lazy container creation; in-memory mode for tests.
//
//  Schema population is split across issues:
//    - Issue 10: SubscriptionSource / SubscriptionRule / FeedItem (RSS)
//    - Issue 06: TorrentTask (BT)
//    - Issue 02: DisclaimerAcceptance
//    - Phase 2 issues: Title / Season / Episode / VersionFile / Tag / WatchProgress
//
//  See docs/adr/0003-swiftdata-persistence.md for rationale and migration policy.

import Foundation
import SwiftData
import OSLog

public final class PersistenceController {

    private static let logger = Logger(subsystem: "iina-magnet", category: "persistence")

    /// Shared production instance, backed by a file in Application Support.
    public static let shared = PersistenceController(inMemory: false)

    /// Convenience for unit tests — no disk writes, no leakage between cases.
    public static func inMemory() -> PersistenceController {
        PersistenceController(inMemory: true)
    }

    public let container: ModelContainer

    private init(inMemory: Bool) {
        // Schema grows per issue:
        //   - Issue 02: DisclaimerAcceptance
        //   - Issue 10: SubscriptionSource / SubscriptionRule / FeedItem
        //   - Issue 06: TorrentTask
        //   - Phase 2: Title / Season / Episode / VersionFile / Tag / WatchProgress
        let schema = Schema([
            DisclaimerAcceptance.self,
        ])

        do {
            if inMemory {
                let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                container = try ModelContainer(for: schema, configurations: [config])
            } else {
                let url = Self.storeURL()
                let config = ModelConfiguration(schema: schema, url: url)
                container = try ModelContainer(for: schema, configurations: [config])
            }
            Self.logger.info("ModelContainer ready (inMemory=\(inMemory))")
        } catch {
            Self.logger.fault("Failed to create ModelContainer: \(error.localizedDescription, privacy: .public)")
            fatalError("iina-magnet failed to open its database: \(error)")
        }
    }

    /// `~/Library/Application Support/iina-magnet/Library.sqlite`.
    /// Creates the directory if needed.
    private static func storeURL() -> URL {
        let fm = FileManager.default
        let appSupport = try! fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true)
        let dir = appSupport.appendingPathComponent("iina-magnet", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("Library.sqlite", isDirectory: false)
    }
}

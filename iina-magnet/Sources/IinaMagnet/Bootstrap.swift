//
//  Bootstrap.swift
//  IinaMagnet
//
//  The single entry point the iina AppDelegate hook calls (Issue 03 will wire it in).
//  Holds the lifecycle of every magnet subsystem: TorrentManager, RssService,
//  SubscriptionScheduler, CompletionPipeline (added in subsequent Phase 1 issues).
//
//  Phase 0 baseline: stub only. Start/shutdown are no-ops.

import Foundation
import OSLog

public enum IinaMagnetBootstrap {

    private static let logger = Logger(subsystem: "iina-magnet", category: "bootstrap")

    private static var didStart = false

    /// Called from `AppDelegate.applicationDidFinishLaunching` (see Issue 03 hook).
    /// Idempotent — safe to call multiple times.
    public static func start() {
        guard !didStart else {
            logger.debug("IinaMagnetBootstrap.start called twice; ignoring second call")
            return
        }
        didStart = true
        logger.info("IinaMagnetBootstrap.start — Phase 0 stub; no subsystems started yet")

        // Phase 1 issues will add:
        //   _ = PersistenceController.shared             // Issue 10
        //   _ = TorrentManager.shared                    // Issue 06
        //   _ = SubscriptionScheduler.shared             // Issue 13
        //   _ = CompletionPipeline.shared                // Issue 17
        //
        // Disclaimer check (Issue 02) runs before any user-facing window opens.
    }

    /// Called from `AppDelegate.applicationWillTerminate` (see Issue 03 hook).
    /// Idempotent.
    public static func shutdown() {
        guard didStart else { return }
        didStart = false
        logger.info("IinaMagnetBootstrap.shutdown — Phase 0 stub")

        // Phase 1 issues will add graceful pause + resume-data save for libtorrent here.
    }
}

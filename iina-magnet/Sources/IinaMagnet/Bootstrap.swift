//
//  Bootstrap.swift
//  IinaMagnet
//
//  Single entry point invoked from iina's AppDelegate hook.
//  Phase 0 wiring:
//   - Install the "Magnet" main menu (RSS Manager, BT Manager, Library, Settings, Disclaimer)
//   - Present the Disclaimer modal on first launch
//   - Open placeholder windows for menu items (real content lands in Issues 14/15/16)
//
//  Phase 1 will append: TorrentManager, RssService, SubscriptionScheduler, CompletionPipeline.

import AppKit
import SwiftUI
import OSLog

@MainActor
public enum IinaMagnetBootstrap {

    private static let logger = Logger(subsystem: "iina-magnet", category: "bootstrap")

    private static var didStart = false

    /// Retained so its debounce state survives across playback samples (Issue 17).
    private static var watchTracker: WatchProgressTracker?

    /// Called from `AppDelegate.applicationDidFinishLaunching`.
    /// Idempotent — safe to call multiple times.
    public static func start() {
        guard !didStart else {
            logger.debug("start called twice; ignoring")
            return
        }
        didStart = true
        logger.info("IinaMagnetBootstrap.start")

        presentDisclaimerIfNeeded()
        startWatchProgressTracking()
    }

    /// Called from `AppDelegate.applicationWillTerminate`.
    /// Idempotent.
    public static func shutdown() {
        guard didStart else { return }
        didStart = false
        logger.info("IinaMagnetBootstrap.shutdown")
    }

    /// Opens the media-library window. The entry point lives on iina's initial
    /// (launch) window — a button below the build badge — which calls this.
    public static func openLibrary() {
        WindowFactory.shared.open(.library, title: "媒体库",
                                  contentSize: .init(width: 1100, height: 720)) {
            LibraryWindowView()
                .modelContainer(PersistenceController.shared.container)
        }
    }

    // MARK: - Watch progress (Issue 17)

    /// Records playback progress from iina into the library. Debounced in the
    /// tracker actor; the surviving samples are written on the main context.
    private static func startWatchProgressTracking() {
        let tracker = WatchProgressTracker { url, position, duration, ended in
            let context = PersistenceController.shared.container.mainContext
            do {
                try WatchProgressWriter(context: context)
                    .record(url: url, positionSec: position, durationSec: duration, ended: ended)
            } catch {
                logger.error("watch progress write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        watchTracker = tracker

        guard let bridge = IinaBridgeRegistry.bridge else {
            logger.notice("no IinaBridge at start; watch-progress tracking inactive")
            return
        }
        bridge.observePlaybackProgress { url, position, duration, ended in
            Task { await tracker.ingest(url: url, positionSec: position,
                                        durationSec: duration, ended: ended) }
        }
        logger.info("watch-progress tracking active")
    }

    // MARK: - Disclaimer

    private static func presentDisclaimerIfNeeded() {
        let coordinator = DisclaimerCoordinator(context: PersistenceController.shared.container.mainContext)
        guard coordinator.needsAcceptance() else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            styleMask: [.titled],   // no close/minimize/resize — user must Agree
            backing: .buffered,
            defer: false
        )
        window.title = "iina-magnet"
        window.center()
        window.isReleasedWhenClosed = false

        let hosting = NSHostingController(rootView: DisclaimerSheet(coordinator: coordinator) {
            window.close()
        })
        window.contentViewController = hosting

        // Present as modal-ish front window; not a real session modal because
        // iina starts other windows asynchronously and we'd deadlock.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

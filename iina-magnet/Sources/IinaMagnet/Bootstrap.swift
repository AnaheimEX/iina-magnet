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
        WindowFactory.shared.flushWindowFrames()
        Task {
            await MikanWebViewStore.shared.flushCookieSnapshot()
        }
    }

    /// Opens the media-library window. The entry point lives on iina's initial
    /// (launch) window — a button below the build badge — which calls this.
    ///
    /// The window adapts to the current display each time it opens: sized to a
    /// fraction of the screen (large, but never fullscreen) and the whole UI is
    /// laid out on a ~1100pt canvas then scaled up to fill it, so every element
    /// grows proportionally and stays easy to click on high-resolution screens.
    public static func openLibrary() {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let width  = max(960, screen.width * 0.74)
        let height = max(640, screen.height * 0.82)
        // SwiftUI points are already DPI-independent — Retina pixel density is
        // handled by the OS (backingScaleFactor), so the UI renders at its
        // natural, comfortably-sized point metrics with no extra zoom. Keep a
        // floor of 1.0 (never enlarge on normal displays) and only nudge up
        // gently on very wide monitors so the layout isn't sparse; the cap keeps
        // text crisp (scaleEffect softens it at higher factors).
        let scale  = min(max(screen.width / 1512, 1.0), 1.3)
        WindowFactory.shared.open(.library, title: "媒体库",
                                  contentSize: CGSize(width: width, height: height)) {
            LibraryWindowView(scale: scale)
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

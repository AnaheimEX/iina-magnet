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

        installLibraryMenuEntry()
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

    // MARK: - Menu installation

    /// Adds the media-library entry to the IINA application menu, directly above
    /// "About IINA" (Phase 3: the library is the app's headline feature, no longer
    /// buried in a submenu). Disclaimer stays auto-presented on first launch.
    private static func installLibraryMenuEntry() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else {
            logger.warning("app menu unavailable at start; cannot install library entry")
            return
        }
        // Idempotency.
        if appMenu.items.contains(where: { $0.title == "媒体库…" }) { return }

        let item = NSMenuItem(title: "媒体库…",
                              action: #selector(MagnetMenuActions.showLibrary(_:)),
                              keyEquivalent: "l")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = MagnetMenuActions.shared

        // Insert above "About IINA" — the About item is the app menu's first item.
        let aboutIdx = appMenu.items.firstIndex { $0.action == Selector(("orderFrontAboutPanel:"))
            || $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:))
            || $0.title.localizedCaseInsensitiveContains("About")
            || $0.title.contains("关于") } ?? 0
        appMenu.insertItem(item, at: aboutIdx)
        appMenu.insertItem(.separator(), at: aboutIdx + 1)
        logger.info("media-library menu entry installed above About at index \(aboutIdx)")
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

// MARK: - Menu action dispatcher

/// Holds the @objc selectors NSMenuItem needs to dispatch into.
/// Phase 1 issues 14/15/16 will replace placeholder bodies with real window openers.
@MainActor
final class MagnetMenuActions: NSObject {

    static let shared = MagnetMenuActions()
    private static let logger = Logger(subsystem: "iina-magnet", category: "menu")

    @objc func showLibrary(_ sender: Any?) {
        WindowFactory.shared.open(.library, title: "媒体库",
                                  contentSize: .init(width: 1100, height: 720)) {
            LibraryWindowView()
                .modelContainer(PersistenceController.shared.container)
        }
    }

    @objc func showDisclaimer(_ sender: Any?) {
        let coordinator = DisclaimerCoordinator(context: PersistenceController.shared.container.mainContext)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Disclaimer"
        window.center()
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: DisclaimerSheet(coordinator: coordinator) {
            window.close()
        })
        window.contentViewController = hosting
        window.makeKeyAndOrderFront(nil)
    }

    private func placeholder(name: String) {
        Self.logger.info("\(name) menu item clicked — placeholder; real implementation in subsequent issues")
        let alert = NSAlert()
        alert.messageText = "\(name) — Coming soon"
        alert.informativeText = "This window is implemented by a later Phase 1 issue. The Magnet menu and Disclaimer flow are working as a Phase 0 milestone."
        alert.alertStyle = .informational
        alert.runModal()
    }
}

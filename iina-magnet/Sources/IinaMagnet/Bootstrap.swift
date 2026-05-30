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

        installMagnetMenu()
        presentDisclaimerIfNeeded()
        startWatchProgressTracking()

        // Phase 1: bring up the actor pipeline in dependency order.
        // CompletionPipeline subscribes to TorrentManager.events; subscribe BEFORE
        // any torrents can be added so we don't miss early finished events.
        Task {
            await TorrentManager.shared.start()
            await CompletionPipeline.shared.start()
            await SubscriptionScheduler.shared.start()
        }
    }

    /// Called from `AppDelegate.applicationWillTerminate`.
    /// Idempotent.
    public static func shutdown() {
        guard didStart else { return }
        didStart = false
        logger.info("IinaMagnetBootstrap.shutdown")
        // Synchronous shutdown so we don't race app exit; block briefly for the actors.
        let sema = DispatchSemaphore(value: 0)
        Task {
            await SubscriptionScheduler.shared.shutdown()
            await CompletionPipeline.shared.shutdown()
            await TorrentManager.shared.shutdown()
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 3)
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

    private static func installMagnetMenu() {
        guard let mainMenu = NSApp.mainMenu else {
            logger.warning("NSApp.mainMenu nil at start; cannot install Magnet menu")
            return
        }

        // Idempotency: only install once even if start() is invoked twice in dev.
        if mainMenu.items.contains(where: { $0.title == "Magnet" }) {
            return
        }

        let magnetItem = NSMenuItem(title: "Magnet", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Magnet")

        submenu.addItem(menuItem(title: "RSS Manager…",
                                 action: #selector(MagnetMenuActions.showRssManager(_:)),
                                 keyEquivalent: "r", modifiers: [.command, .shift]))
        submenu.addItem(menuItem(title: "BT Manager…",
                                 action: #selector(MagnetMenuActions.showBtManager(_:)),
                                 keyEquivalent: "b", modifiers: [.command, .shift]))
        submenu.addItem(menuItem(title: "Library…",
                                 action: #selector(MagnetMenuActions.showLibrary(_:)),
                                 keyEquivalent: "l", modifiers: [.command, .shift]))
        submenu.addItem(.separator())
        submenu.addItem(menuItem(title: "Settings…",
                                 action: #selector(MagnetMenuActions.showSettings(_:)),
                                 keyEquivalent: ""))
        submenu.addItem(menuItem(title: "Disclaimer…",
                                 action: #selector(MagnetMenuActions.showDisclaimer(_:)),
                                 keyEquivalent: ""))

        magnetItem.submenu = submenu

        // Insert before "Window" if present, else append.
        let insertIdx = mainMenu.items.firstIndex { $0.title == "Window" } ?? mainMenu.items.count
        mainMenu.insertItem(magnetItem, at: insertIdx)
        logger.info("Magnet menu installed at index \(insertIdx)")
    }

    private static func menuItem(title: String,
                                 action: Selector,
                                 keyEquivalent: String,
                                 modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        if !modifiers.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        item.target = MagnetMenuActions.shared
        return item
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

    @objc func showRssManager(_ sender: Any?) {
        WindowFactory.shared.open(.rssManager, title: "RSS Manager",
                                  contentSize: .init(width: 1000, height: 640)) {
            RssManagerView()
                .modelContainer(PersistenceController.shared.container)
        }
    }

    @objc func showBtManager(_ sender: Any?) {
        WindowFactory.shared.open(.btManager, title: "BT Manager",
                                  contentSize: .init(width: 1000, height: 540)) {
            BtManagerView()
                .modelContainer(PersistenceController.shared.container)
        }
    }

    @objc func showLibrary(_ sender: Any?) {
        WindowFactory.shared.open(.library, title: "Library",
                                  contentSize: .init(width: 1100, height: 720)) {
            LibraryWindowView()
                .modelContainer(PersistenceController.shared.container)
        }
    }

    @objc func showSettings(_ sender: Any?) {
        WindowFactory.shared.open(.settings, title: "Settings",
                                  contentSize: .init(width: 600, height: 460)) {
            MagnetSettingsView()
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

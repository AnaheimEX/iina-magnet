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
    }

    /// Called from `AppDelegate.applicationWillTerminate`.
    /// Idempotent.
    public static func shutdown() {
        guard didStart else { return }
        didStart = false
        logger.info("IinaMagnetBootstrap.shutdown")
        // Phase 1 issues will add graceful libtorrent pause + resume-data save here.
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
        let libraryItem = menuItem(title: "Library…",
                                   action: #selector(MagnetMenuActions.showLibrary(_:)),
                                   keyEquivalent: "l", modifiers: [.command, .shift])
        libraryItem.isEnabled = false   // Phase 2 enables
        submenu.addItem(libraryItem)
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

    @objc func showRssManager(_ sender: Any?)  { placeholder(name: "RSS Manager") }
    @objc func showBtManager(_ sender: Any?)   { placeholder(name: "BT Manager") }
    @objc func showLibrary(_ sender: Any?)     { placeholder(name: "Library") }
    @objc func showSettings(_ sender: Any?)    { placeholder(name: "Settings") }

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

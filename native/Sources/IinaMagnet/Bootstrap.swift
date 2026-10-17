import AppKit
import SwiftUI
import OSLog

/// Host lifecycle and independent cloud-service windows.
@MainActor
public enum IinaMagnetBootstrap {
    private static let logger = Logger(subsystem: "iina-magnet", category: "bootstrap")
    private static var didStart = false

    public static func start() {
        guard !didStart else { return }
        didStart = true
        presentDisclaimerIfNeeded()
        Task.detached(priority: .utility) {
            await PikPakAuth.shared.restoreFromWebSessionIfNeeded()
        }
    }

    public static func shutdown() {
        guard didStart else { return }
        didStart = false
        WindowFactory.shared.flushWindowFrames()
        Task { await MikanWebViewStore.shared.flushCookieSnapshot() }
    }

    private static var cloudWindowSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: min(screen.width, max(960, screen.width * 0.74)),
                      height: min(screen.height, max(640, screen.height * 0.82)))
    }

    public static func openPikPak() {
        WindowFactory.shared.open(.pikpak, title: "PikPak 网盘", contentSize: cloudWindowSize) {
            PikPakView(onBack: { WindowFactory.shared.close(.pikpak) })
        }
    }

    public static func openMikan() {
        WindowFactory.shared.open(.mikan, title: "蜜柑计划", contentSize: cloudWindowSize) {
            MikanView(onBack: { WindowFactory.shared.close(.mikan) })
        }
    }

    // MARK: - Disclaimer

    private static func presentDisclaimerIfNeeded() {
        let coordinator = DisclaimerCoordinator(context: DisclaimerStore.shared.container.mainContext)
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

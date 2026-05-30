//
//  WindowFactory.swift
//  IinaMagnet
//
//  Helper that opens an NSWindow hosting a SwiftUI view. iina's AppDelegate
//  is an NSApplicationDelegate (not a SwiftUI App) so we manage windows by
//  hand instead of going through @SceneStorage / WindowGroup.
//
//  Each window key is tracked so subsequent opens raise the existing window
//  rather than creating duplicates.

import AppKit
import SwiftUI

@MainActor
public enum MagnetWindowKey: String {
    case library     = "iina-magnet.library"
    case disclaimer  = "iina-magnet.disclaimer"
}

@MainActor
public final class WindowFactory {

    public static let shared = WindowFactory()
    private var windows: [String: NSWindow] = [:]

    private init() {}

    public func open<Content: View>(_ key: MagnetWindowKey,
                                    title: String,
                                    contentSize: CGSize = .init(width: 900, height: 600),
                                    @ViewBuilder builder: () -> Content) {
        // Reopen: re-adapt to the current screen — fresh content (so a new
        // scale takes effect), resized + recentered — then raise.
        if let existing = windows[key.rawValue] {
            existing.title = title
            existing.contentViewController = NSHostingController(rootView: builder())
            existing.setContentSize(contentSize)
            existing.center()
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = NSHostingController(rootView: builder())
        window.setContentSize(contentSize)
        window.center()
        window.isReleasedWhenClosed = false
        windows[key.rawValue] = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

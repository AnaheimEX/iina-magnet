//
//  WindowFactory.swift
//  IinaMagnet
//
//  Helper that opens an NSWindow hosting a SwiftUI view. iina's AppDelegate
//  is an NSApplicationDelegate (not a SwiftUI App) so we manage windows by
//  hand instead of going through @SceneStorage / WindowGroup.
//
//  Each window key is tracked so subsequent opens raise existing window
//  rather creating duplicates.
//

import AppKit
import SwiftUI

@MainActor
public enum MagnetWindowKey: String {
    case library = "iina-magnet.library"
    case disclaimer = "iina-magnet.disclaimer"
}

@MainActor
public final class WindowFactory {
    public static let shared = WindowFactory()

    private static let minWindowSize = NSSize(width: 420, height: 320)

    private var windows: [String: NSWindow] = [:]
    private var frameObservers: [String: [NSObjectProtocol]] = [:]
    private let frameStorage = UserDefaults.standard

    private init() {}

    public func open<Content: View>(
        _ key: MagnetWindowKey,
        title: String,
        contentSize: CGSize = .init(width: 900, height: 600),
        @ViewBuilder builder: () -> Content
    ) {
        if let existing = windows[key.rawValue] {
            // Reopen existing window without overriding user-resized size.
            existing.title = title
            existing.contentViewController = NSHostingController(rootView: builder())
            restoreSavedWindowFrame(for: key, window: existing)
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
        window.isReleasedWhenClosed = false

        let didRestoreFrame = restoreSavedWindowFrame(for: key, window: window)
        if !didRestoreFrame {
            window.center()
        }
        installFrameTracking(for: key, window: window)

        windows[key.rawValue] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called during app shutdown to make sure latest window geometry is durable
    /// even if a close event was missed.
    public func flushWindowFrames() {
        for (rawKey, window) in windows {
            guard let key = MagnetWindowKey(rawValue: rawKey) else { continue }
            saveWindowFrame(for: key, window: window)
        }
        frameStorage.synchronize()
    }

    private func frameStorageKey(for key: MagnetWindowKey) -> String {
        "iina-magnet.window.frame.\(key.rawValue)"
    }

    @discardableResult
    private func restoreSavedWindowFrame(for key: MagnetWindowKey, window: NSWindow) -> Bool {
        guard let frameString = frameStorage.string(forKey: frameStorageKey(for: key)),
              !frameString.isEmpty else {
            return false
        }

        let frame = NSRectFromString(frameString)
        guard frame != .zero else { return false }

        let visibleFrame = NSScreen.screens.reduce(NSScreen.main?.visibleFrame ?? .zero) { current, screen in
            guard current != .zero else { return screen.visibleFrame }
            return current.union(screen.visibleFrame)
        }

        let clamped = clampFrame(frame, into: visibleFrame)
        guard clamped != .zero else {
            return false
        }

        window.setFrame(clamped, display: false)
        return true
    }

    private func installFrameTracking(for key: MagnetWindowKey, window: NSWindow) {
        let rawKey = key.rawValue
        guard frameObservers[rawKey] == nil else { return }

        var observers: [NSObjectProtocol] = []
        let trackNotifications: [NSNotification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didResizeNotification,
        ]

        for note in trackNotifications {
            observers.append(
                NotificationCenter.default.addObserver(forName: note, object: window, queue: .main) { [weak self] _ in
                    self?.saveWindowFrame(for: key, window: window)
                }
            )
        }

        observers.append(
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.saveWindowFrame(for: key, window: window)
                self?.removeWindowTracking(for: rawKey)
                self?.windows.removeValue(forKey: rawKey)
            }
        )

        frameObservers[rawKey] = observers
    }

    private func removeWindowTracking(for rawKey: String) {
        guard let observers = frameObservers.removeValue(forKey: rawKey) else { return }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func saveWindowFrame(for key: MagnetWindowKey, window: NSWindow) {
        frameStorage.set(NSStringFromRect(window.frame), forKey: frameStorageKey(for: key))
    }

    private func clampFrame(_ frame: NSRect, into hostFrame: NSRect) -> NSRect {
        guard hostFrame != .zero else { return .zero }

        var sanitized = frame

        sanitized.size.width = min(max(sanitized.size.width, Self.minWindowSize.width), hostFrame.width)
        sanitized.size.height = min(max(sanitized.size.height, Self.minWindowSize.height), hostFrame.height)

        sanitized.origin.x = min(max(sanitized.origin.x, hostFrame.minX), hostFrame.maxX - sanitized.size.width)
        sanitized.origin.y = min(max(sanitized.origin.y, hostFrame.minY), hostFrame.maxY - sanitized.size.height)

        return sanitized
    }
}

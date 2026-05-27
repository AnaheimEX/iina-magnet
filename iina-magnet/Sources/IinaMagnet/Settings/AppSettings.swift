//
//  AppSettings.swift
//  IinaMagnet
//
//  User-facing settings backed by UserDefaults. Single observable source
//  of truth for paths + BT/RSS defaults (Issue 16 reads/writes via SwiftUI;
//  CompletionPipeline reads at event time).

import Foundation
import Observation

@MainActor
@Observable
public final class AppSettings {

    public static let shared = AppSettings()

    // MARK: General

    public var cacheDirectory: URL {
        get { _read(forKey: "cacheDirectory") ?? defaultCacheDirectory }
        set { _write(newValue, forKey: "cacheDirectory") }
    }

    public var completedDirectory: URL {
        get { _read(forKey: "completedDirectory") ?? defaultCompletedDirectory }
        set { _write(newValue, forKey: "completedDirectory") }
    }

    /// When true, finished torrents are moved from cache → completedDirectory.
    public var autoMoveOnCompletion: Bool {
        get { defaults.object(forKey: "autoMoveOnCompletion") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoMoveOnCompletion") }
    }

    // MARK: BitTorrent

    public var listenPort: Int {
        get { defaults.object(forKey: "listenPort") as? Int ?? 6881 }
        set { defaults.set(newValue, forKey: "listenPort") }
    }

    public var enableDHT: Bool {
        get { defaults.object(forKey: "enableDHT") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enableDHT") }
    }

    public var enablePEX: Bool {
        get { defaults.object(forKey: "enablePEX") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enablePEX") }
    }

    public var enableLSD: Bool {
        get { defaults.object(forKey: "enableLSD") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enableLSD") }
    }

    public var enableUPnP: Bool {
        get { defaults.object(forKey: "enableUPnP") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "enableUPnP") }
    }

    public enum SeedingMode: String, Codable, CaseIterable, Sendable {
        case zero
        case ratio1x
        case ratio2x
        case forever
    }

    public var seedingMode: SeedingMode {
        get { defaults.string(forKey: "seedingMode").flatMap(SeedingMode.init(rawValue:)) ?? .zero }
        set { defaults.set(newValue.rawValue, forKey: "seedingMode") }
    }

    /// In MB; 0 = no warning.
    public var diskWarnThresholdGB: Int {
        get { defaults.object(forKey: "diskWarnThresholdGB") as? Int ?? 10 }
        set { defaults.set(newValue, forKey: "diskWarnThresholdGB") }
    }

    // MARK: RSS

    public var defaultPollIntervalSeconds: Int {
        get { defaults.object(forKey: "defaultPollIntervalSeconds") as? Int ?? 1800 }
        set { defaults.set(newValue, forKey: "defaultPollIntervalSeconds") }
    }

    public var autoStartDownloadOnMatch: Bool {
        get { defaults.object(forKey: "autoStartDownloadOnMatch") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoStartDownloadOnMatch") }
    }

    // MARK: Internals

    private let defaults = UserDefaults.standard
    private init() {}

    private static var supportRoot: URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport.appendingPathComponent("iina-magnet", isDirectory: true)
    }

    private var defaultCacheDirectory: URL { Self.supportRoot.appendingPathComponent("cache", isDirectory: true) }
    private var defaultCompletedDirectory: URL {
        FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("iina-magnet", isDirectory: true)
            ?? Self.supportRoot.appendingPathComponent("completed", isDirectory: true)
    }

    private func _read(forKey key: String) -> URL? {
        guard let bookmark = defaults.data(forKey: key) else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmark,
                        options: [.withoutUI],
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale)
    }

    private func _write(_ url: URL, forKey key: String) {
        if let bookmark = try? url.bookmarkData(options: .minimalBookmark,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil) {
            defaults.set(bookmark, forKey: key)
        }
    }
}

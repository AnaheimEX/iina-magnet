//
//  IinaBridge.swift
//  IinaMagnet
//
//  Thin protocol the iina side implements to give IinaMagnet what it
//  needs to drive playback (opening a URL in iina's PlayerCore) and to
//  read the current playback position. Decouples IinaMagnet from iina's
//  actual module — IinaMagnet remains buildable as a standalone SPM target.
//
//  Wired in iina's AppDelegate (// MARK: iina-magnet hook).

import Foundation

/// Extra mpv hints for a playback request. Used for remote (PikPak) streams:
/// a larger network cache smooths buffering and a User-Agent avoids CDN
/// throttling. Local library playback ignores these.
public struct PlaybackOptions: Sendable {
    public var userAgent: String?
    /// Enlarge mpv's demuxer / network cache for smoother remote streaming.
    public var enlargeNetworkCache: Bool

    public init(userAgent: String? = nil, enlargeNetworkCache: Bool = false) {
        self.userAgent = userAgent
        self.enlargeNetworkCache = enlargeNetworkCache
    }
}

@MainActor
public protocol IinaBridge: AnyObject, Sendable {
    /// Asks iina to start playing the given URL in its current PlayerCore.
    func openForPlayback(_ url: URL)

    /// Plays `url` applying `options` (network cache / User-Agent). The default
    /// ignores options and calls `openForPlayback(_:)`, so existing bridges and
    /// test mocks keep working unchanged.
    func openForPlayback(_ url: URL, options: PlaybackOptions)

    /// Current playback position in seconds, nil when not playing or unknown.
    var currentVideoPositionSec: Double? { get }

    /// Registers a handler invoked as playback advances and at end-of-file, so
    /// the library can record watch progress (Issue 17). `positionSec` /
    /// `durationSec` are seconds; `ended` is true when the file finished. Called
    /// on the main actor. The default no-op lets older bridges / tests opt out.
    func observePlaybackProgress(
        _ handler: @escaping @MainActor (_ url: URL, _ positionSec: Double,
                                         _ durationSec: Double, _ ended: Bool) -> Void)
}

public extension IinaBridge {
    func openForPlayback(_ url: URL, options: PlaybackOptions) { openForPlayback(url) }

    func observePlaybackProgress(
        _ handler: @escaping @MainActor (URL, Double, Double, Bool) -> Void) {}
}

@MainActor
public enum IinaBridgeRegistry {
    public static weak var bridge: (any IinaBridge)?
}

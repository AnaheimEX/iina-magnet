//
//  IinaBridge.swift
//  IinaMagnet
//
//  Playback contract implemented by the native companion. Requests are handed
//  to the official IINA plugin without linking against IINA's application code.

import Foundation

/// Extra mpv hints for a playback request. Used for remote (PikPak) streams:
/// a larger network cache smooths buffering and a User-Agent avoids CDN
/// throttling.
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

    /// Returns only after the player has loaded the requested file.
    func openForPlaybackAndWait(_ url: URL, options: PlaybackOptions) async throws


}

public extension IinaBridge {
    func openForPlaybackAndWait(_ url: URL, options: PlaybackOptions) async throws {
        throw NSError(domain: "IinaBridge", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "播放器不支持加载状态确认"])
    }

    func openForPlayback(_ url: URL, options: PlaybackOptions) { openForPlayback(url) }

}

@MainActor
public enum IinaBridgeRegistry {
    public static weak var bridge: (any IinaBridge)?
}

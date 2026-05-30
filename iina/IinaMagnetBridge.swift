//
//  IinaMagnetBridge.swift
//  iina
//
//  iina-magnet hook (Issue 08): implements IinaMagnet.IinaBridge so the
//  magnet module can ask iina to open URLs and read the playback position
//  without IinaMagnet having to import iina.
//
//  This file is the *only* iina-side hook for streaming; everything else
//  in this directory is upstream-clean.

import Foundation
import IinaMagnet

@MainActor
final class IinaMagnetBridgeImpl: NSObject, IinaBridge {

    static let shared = IinaMagnetBridgeImpl()

    func openForPlayback(_ url: URL) {
        let player = PlayerCore.active
        // Restore the stream-probe defaults in case a prior remote stream
        // tightened them on this shared player core, so local-file format
        // detection stays robust.
        player.mpv.setInt(MPVOption.Demuxer.demuxerLavfProbesize, 5_000_000)
        player.mpv.setDouble(MPVOption.Demuxer.demuxerLavfAnalyzeduration, 0)
        player.openURL(url)
    }

    /// Applies a remote-stream profile (User-Agent + fast start + a generous
    /// buffer) before loading, so PikPak's overseas CDN starts quickly and then
    /// plays smoothly. Surge (TUN) handles proxy routing by domain rule —
    /// nothing proxy-specific here.
    func openForPlayback(_ url: URL, options: PlaybackOptions) {
        let player = PlayerCore.active
        if let userAgent = options.userAgent {
            _ = player.mpv.setString(MPVOption.Network.userAgent, userAgent)
        }
        if options.enlargeNetworkCache {
            player.mpv.setFlag(MPVOption.Cache.cache, true)
            // Fast start: begin playing as soon as the first frames arrive
            // (don't pre-fill the cache) and probe far less of the stream before
            // deciding its format — the biggest first-frame win on a
            // high-latency link. PikPak serves standard MP4/MKV, so a short
            // probe is enough.
            player.mpv.setFlag(MPVOption.Cache.cachePauseInitial, false)
            player.mpv.setInt(MPVOption.Demuxer.demuxerLavfProbesize, 2 * 1024 * 1024)   // 2 MiB
            player.mpv.setDouble(MPVOption.Demuxer.demuxerLavfAnalyzeduration, 1)        // 1 s
            // Don't hang indefinitely on a stalled connection.
            player.mpv.setInt(MPVOption.Network.networkTimeout, 60)
            // Generous demuxer buffer for smooth playback once started (filled
            // in the background; does not delay the first frame).
            player.mpv.setInt(MPVOption.Demuxer.demuxerMaxBytes, 256 * 1024 * 1024)      // 256 MiB
            player.mpv.setInt(MPVOption.Demuxer.demuxerMaxBackBytes, 64 * 1024 * 1024)   // 64 MiB
            player.mpv.setDouble(MPVOption.Demuxer.demuxerReadaheadSecs, 60)
        }
        player.openURL(url)
    }

    var currentVideoPositionSec: Double? {
        PlayerCore.active.info.videoPosition?.second
    }

    // MARK: iina-magnet hook (Issue 17 · watch-progress)

    /// Sampling timer; reports the active player's position to the library so it
    /// can record watch progress. A coarse 5 s tick is enough — the library
    /// debounces further and completes an episode at ≥90 % regardless.
    private var progressTimer: Timer?
    private var progressHandler: (@MainActor (URL, Double, Double, Bool) -> Void)?

    func observePlaybackProgress(
        _ handler: @escaping @MainActor (URL, Double, Double, Bool) -> Void) {
        progressHandler = handler
        progressTimer?.invalidate()
        // Tolerant of being created off the main run loop's common modes so it
        // keeps firing while menus/sheets are open.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func sampleProgress() {
        let info = PlayerCore.active.info
        guard let url = info.currentURL,
              url.isFileURL,
              let position = info.videoPosition?.second,
              let duration = info.videoDuration?.second, duration > 0 else { return }

        // Near the end counts as ended so the file is marked watched even if the
        // player stops a beat before the exact duration. Guard short clips so a
        // sub-2 s file isn't flagged ended on its first sample.
        let ended = duration > 2 && position >= duration - 1
        progressHandler?(url, position, duration, ended)
    }
}

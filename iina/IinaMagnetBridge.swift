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
        PlayerCore.active.openURL(url)
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

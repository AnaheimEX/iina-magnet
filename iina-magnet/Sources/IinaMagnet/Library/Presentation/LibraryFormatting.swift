//
//  LibraryFormatting.swift
//  IinaMagnet
//
//  Pure formatting helpers for the presentation layer — file sizes, playback
//  timecodes, and the "续播…" resume label. Kept separate from the view model so
//  the string formatting is unit-testable without building any SwiftData store.

import Foundation

public enum LibraryFormatting {

    /// Human file size, e.g. "5.8 GB". Uses the binary (file) convention.
    public static func size(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: bytes)
    }

    /// "H:MM:SS" (hours omitted when zero → "MM:SS") for a playback position.
    /// `forceHours` keeps the hours field even when zero, so a position/duration
    /// pair shares one width (e.g. "05:00 / 2:05:00" → "0:05:00 / 2:05:00").
    public static func timecode(_ seconds: TimeInterval, forceHours: Bool = false) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return (h > 0 || forceHours) ? String(format: "%d:%02d:%02d", h, m, s)
                                     : String(format: "%02d:%02d", m, s)
    }

    /// Builds the design's resume label from a watch progress.
    ///
    /// - tv:    "续播 第14集" (+ " · 还剩 11 分钟" when duration is known)
    /// - movie: "续播 · 01:12:30 / 02:05:00"
    public static func resumeLabel(episodeNumber: Int?,
                                   positionSec: TimeInterval,
                                   durationSec: TimeInterval) -> String {
        if let ep = episodeNumber, ep > 0 {
            var label = "续播 第\(ep)集"
            if durationSec > 0 {
                let remainingMin = Int(((durationSec - positionSec) / 60).rounded(.up))
                if remainingMin > 0 { label += " · 还剩 \(remainingMin) 分钟" }
            }
            return label
        }
        // Movie (or season-0 placeholder): show absolute timecodes when known,
        // both fields sharing the duration's width so they line up.
        if durationSec > 0 {
            let hours = durationSec >= 3600
            return "续播 · \(timecode(positionSec, forceHours: hours)) / \(timecode(durationSec, forceHours: hours))"
        }
        return "续播"
    }

    /// Fraction watched, clamped to 0...1. Zero when duration is unknown.
    public static func progress(positionSec: TimeInterval, durationSec: TimeInterval) -> Double {
        guard durationSec > 0 else { return 0 }
        return min(1, max(0, positionSec / durationSec))
    }
}

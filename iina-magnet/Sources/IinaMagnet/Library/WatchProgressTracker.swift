//
//  WatchProgressTracker.swift
//  IinaMagnet
//
//  Actor in front of WatchProgressWriter (Issue 17): debounces the high-frequency
//  playback samples iina emits so SwiftData isn't written on every tick, then
//  hands surviving samples to a main-actor writer closure. The iina callback only
//  *delivers* the sample (into `ingest`); all bookkeeping happens inside the actor.

import Foundation
import OSLog

public actor WatchProgressTracker {

    private static let logger = Logger(subsystem: "iina-magnet", category: "watch-progress")

    /// Persist at most this often per file while playing…
    private let minInterval: TimeInterval
    /// …unless the position jumped by at least this much (seek), or the file ended.
    private let minPositionDelta: Double

    /// Performs the actual write on the main actor (the library's main context).
    private let write: @MainActor (URL, Double, Double, Bool) -> Void

    private struct LastWrite { var time: Date; var position: Double; var ended: Bool }
    private var lastWrites: [String: LastWrite] = [:]      // keyed by url.path

    public init(minInterval: TimeInterval = 5,
                minPositionDelta: Double = 30,
                write: @escaping @MainActor (URL, Double, Double, Bool) -> Void) {
        self.minInterval = minInterval
        self.minPositionDelta = minPositionDelta
        self.write = write
    }

    /// Feeds a playback sample through the debounce. An EOF sample writes the
    /// completion once, but a player parked at EOF (ended=true every tick at the
    /// same spot) is collapsed so we don't re-save every interval.
    public func ingest(url: URL, positionSec: Double, durationSec: Double,
                       ended: Bool, now: Date = .now) async {
        let key = url.path
        if let last = lastWrites[key] {
            if ended {
                // Already recorded the completion at ~this spot → skip the churn.
                // A new playthrough (position rewound) jumps past the delta and writes.
                if last.ended, abs(positionSec - last.position) < minPositionDelta { return }
            } else if now.timeIntervalSince(last.time) < minInterval,
                      abs(positionSec - last.position) < minPositionDelta {
                return   // too soon and barely moved
            }
        }
        lastWrites[key] = LastWrite(time: now, position: positionSec, ended: ended)
        await write(url, positionSec, durationSec, ended)
    }
}

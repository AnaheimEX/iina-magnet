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

@MainActor
public protocol IinaBridge: AnyObject, Sendable {
    /// Asks iina to start playing the given URL in its current PlayerCore.
    func openForPlayback(_ url: URL)

    /// Current playback position in seconds, nil when not playing or unknown.
    var currentVideoPositionSec: Double? { get }
}

@MainActor
public enum IinaBridgeRegistry {
    public static weak var bridge: (any IinaBridge)?
}

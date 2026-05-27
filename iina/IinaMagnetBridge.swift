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
}

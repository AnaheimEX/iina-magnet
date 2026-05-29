//
//  VersionFile.swift
//  IinaMagnet
//
//  One concrete file on disk for an Episode (Phase 2, Issue 01). An episode can
//  have several VersionFiles (different resolutions / release groups); watch
//  progress is keyed on (title, season, episode) — NOT on VersionFile — so it is
//  shared across versions (PRD US-20).
//
//  `fileFingerprint` ("<st_dev>:<st_ino>:<size>") dedups the scanner (Issue 04):
//  re-scanning the same file updates the existing row instead of inserting.

import Foundation
import SwiftData

@Model
public final class VersionFile {

    public var fileURL: URL
    public var bookmark: Data?          // security-scoped bookmark for sandbox-safe access
    public var fileSizeBytes: Int64

    @Attribute(.unique) public var fileFingerprint: String

    public var resolution: String?     // normalized, e.g. "1080p" / "2160p"
    public var releaseGroup: String?
    public var languages: [String]     // subtitle languages found alongside
    public var isMissing: Bool         // file no longer on disk; row kept for history

    public var episode: Episode?

    public init(fileURL: URL,
                fileFingerprint: String,
                fileSizeBytes: Int64,
                resolution: String? = nil,
                releaseGroup: String? = nil,
                languages: [String] = [],
                bookmark: Data? = nil) {
        self.fileURL = fileURL
        self.fileFingerprint = fileFingerprint
        self.fileSizeBytes = fileSizeBytes
        self.resolution = resolution
        self.releaseGroup = releaseGroup
        self.languages = languages
        self.bookmark = bookmark
        self.isMissing = false
    }
}

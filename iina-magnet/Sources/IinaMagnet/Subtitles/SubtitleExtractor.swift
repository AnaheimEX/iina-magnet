//
//  SubtitleExtractor.swift
//  IinaMagnet
//
//  Pure-function deep module (Issue 09). Plans the copy of in-torrent
//  subtitle files to the video's sidecar location so that mpv auto-loads
//  them on playback.
//
//  Public surface is split into plan() (no IO) and execute() (does the
//  actual copies via a FileSystemAccessor protocol — mockable for tests).

import Foundation

// MARK: - Types

public struct SubtitleCopy: Sendable, Equatable {
    public let source: URL
    public let destination: URL              // <videoDir>/<videoBasename>.<lang>.<ext>
    public let detectedLanguage: String      // BCP-47; "und" when unknown

    public init(source: URL, destination: URL, detectedLanguage: String) {
        self.source = source
        self.destination = destination
        self.detectedLanguage = detectedLanguage
    }
}

public struct SubtitleExtractionPlan: Sendable, Equatable {
    public let video: URL
    public let copies: [SubtitleCopy]

    public init(video: URL, copies: [SubtitleCopy]) {
        self.video = video
        self.copies = copies
    }
}

// MARK: - FileSystem abstraction

public protocol FileSystemAccessor: Sendable {
    func enumerate(directory: URL) throws -> [URL]
    func fileExists(at: URL) -> Bool
    func copy(from source: URL, to destination: URL) throws
}

public struct RealFileSystem: FileSystemAccessor {
    public init() {}

    public func enumerate(directory: URL) throws -> [URL] {
        var results: [URL] = []
        if let it = FileManager.default.enumerator(at: directory,
                                                   includingPropertiesForKeys: [.isRegularFileKey],
                                                   options: []) {
            for case let url as URL in it {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    results.append(url)
                }
            }
        }
        return results
    }

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func copy(from source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

// MARK: - SubtitleExtractor

public enum SubtitleExtractor {

    public static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "flv", "webm"
    ]

    public static let subtitleExtensions: Set<String> = [
        "srt", "ass", "ssa", "vtt", "sub", "idx", "sup"
    ]

    /// Returns a list of plans — one per video file — listing the subtitle copies
    /// that should be made into the video's sidecar layout.
    public static func plan(rootDirectory: URL, fs: FileSystemAccessor = RealFileSystem()) throws -> [SubtitleExtractionPlan] {
        let all = try fs.enumerate(directory: rootDirectory)
        let videos = all.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
        let subs   = all.filter { subtitleExtensions.contains($0.pathExtension.lowercased()) }

        guard !videos.isEmpty, !subs.isEmpty else { return [] }

        var plans: [URL: [SubtitleCopy]] = [:]
        // Track existing destinations so we don't collide when multiple subs map to the same name.
        var allocatedDestinations: Set<URL> = []

        // Strategy:
        // 1) Same-basename match (video.mkv ↔ video.ass / video.cht.ass)
        // 2) Episode-number match within same or nested directory
        // 3) Unmatched subs are skipped silently

        for sub in subs {
            guard let target = bestMatch(video: nil, sub: sub, videos: videos) else { continue }
            let lang = detectLanguage(filename: sub.lastPathComponent)
            let dst = uniqueSidecarPath(video: target,
                                        sub: sub,
                                        language: lang,
                                        already: allocatedDestinations,
                                        fs: fs)
            allocatedDestinations.insert(dst)

            let copy = SubtitleCopy(source: sub, destination: dst, detectedLanguage: lang)
            plans[target, default: []].append(copy)
        }

        return plans
            .map { SubtitleExtractionPlan(video: $0.key, copies: $0.value) }
            .sorted { $0.video.path < $1.video.path }
    }

    /// Executes the copies. Idempotent — skips entries whose destination already exists.
    public static func execute(_ plans: [SubtitleExtractionPlan], fs: FileSystemAccessor = RealFileSystem()) throws {
        for plan in plans {
            for copy in plan.copies {
                if fs.fileExists(at: copy.destination) { continue }
                try fs.copy(from: copy.source, to: copy.destination)
            }
        }
    }

    // MARK: - Helpers

    /// Picks the best video file for a given subtitle.
    /// Preference order: same basename → same-directory closest by Levenshtein → nearest by episode number.
    private static func bestMatch(video _: URL?, sub: URL, videos: [URL]) -> URL? {
        let subStem = stripLangAndExtension(filename: sub.lastPathComponent)

        // 1) Exact basename match (ignoring lang suffix and extension)
        if let exact = videos.first(where: {
            $0.deletingPathExtension().lastPathComponent == subStem
        }) {
            return exact
        }

        // 2) Same directory, single video → match
        let subDir = sub.deletingLastPathComponent()
        let sameDirVideos = videos.filter { $0.deletingLastPathComponent() == subDir }
        if sameDirVideos.count == 1 { return sameDirVideos.first }

        // 3) Episode number match (e.g. "...E03..." in both)
        if let subEp = episodeNumber(in: sub.lastPathComponent) {
            if let v = videos.first(where: { episodeNumber(in: $0.lastPathComponent) == subEp }) {
                return v
            }
        }

        // 4) If exactly one video in the whole tree, default to it
        if videos.count == 1 { return videos.first }

        return nil
    }

    /// Builds the sidecar destination: <videoDir>/<videoBasename>.<lang>.<ext>
    /// If destination already allocated or exists on disk, appends ".1", ".2"… to avoid clobbering.
    private static func uniqueSidecarPath(video: URL,
                                          sub: URL,
                                          language: String,
                                          already: Set<URL>,
                                          fs: FileSystemAccessor) -> URL {
        let videoDir = video.deletingLastPathComponent()
        let videoBase = video.deletingPathExtension().lastPathComponent
        let subExt = sub.pathExtension.lowercased()

        var attempt = "\(videoBase).\(language).\(subExt)"
        var i = 1
        var candidate = videoDir.appendingPathComponent(attempt)
        while already.contains(candidate) || fs.fileExists(at: candidate) {
            attempt = "\(videoBase).\(language).\(i).\(subExt)"
            candidate = videoDir.appendingPathComponent(attempt)
            i += 1
            if i > 100 { break }  // safety
        }
        return candidate
    }

    // Strip a trailing language suffix and the file extension.
    // "Show.S01E01.chs.ass" → "Show.S01E01"
    // "Show.S01E01.ass"    → "Show.S01E01"
    private static func stripLangAndExtension(filename: String) -> String {
        var name = (filename as NSString).deletingPathExtension
        // If the last component is a language token, strip it.
        let lower = name.lowercased()
        for tag in langTokens.keys {
            let suffix = ".\(tag)"
            if lower.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        return name
    }

    private static let langTokens: [String: String] = [
        // Simplified Chinese
        "chs": "zh-Hans", "sc": "zh-Hans", "gb": "zh-Hans", "简": "zh-Hans", "简体": "zh-Hans",
        // Traditional Chinese
        "cht": "zh-Hant", "tc": "zh-Hant", "big5": "zh-Hant", "繁": "zh-Hant", "繁體": "zh-Hant",
        // Japanese
        "jp": "ja", "jpn": "ja", "ja": "ja", "日": "ja",
        // English
        "en": "en", "eng": "en", "english": "en",
        // Korean
        "kr": "ko", "kor": "ko", "ko": "ko", "韩": "ko",
    ]

    public static func detectLanguage(filename: String) -> String {
        let lower = (filename as NSString).deletingPathExtension.lowercased()
        let nameTokens = lower.split(whereSeparator: { ".-_ ".contains($0) })
        for piece in nameTokens.reversed() {
            if let lang = langTokens[String(piece)] { return lang }
        }
        // Substring scan for CJK markers like "简" / "繁" / "日"
        for (token, lang) in langTokens {
            if filename.contains(token) { return lang }
        }
        return "und"
    }

    private static let episodeRegex: Regex<(Substring, Substring)> = {
        // Match S01E03, E03, " 03 ", etc. The capture is the episode digits.
        // Use a permissive regex; combine with a stricter season+episode form.
        // swiftlint:disable:next force_try
        try! Regex(#"(?i)(?:S\d{1,3}E|\bE| )0*(\d{1,4})"#)
    }()

    private static func episodeNumber(in filename: String) -> Int? {
        // Bare-number filename: "01.chs.ass" → strip lang+ext → "01" → 1
        let cleaned = stripLangAndExtension(filename: filename)
        if let n = Int(cleaned) { return n }

        // Embedded patterns: "Show.S01E03", "Show - 03 [1080p]"
        if let m = filename.firstMatch(of: episodeRegex) {
            return Int(m.output.1)
        }
        return nil
    }
}

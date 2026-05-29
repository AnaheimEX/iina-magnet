//
//  FilenameParser.swift
//  IinaMagnet
//
//  Deep module (Phase 2, Issue 03): turns a video filename into structured
//  fields. Anitomy (via AnitomyBridge) is the primary parser; a built-in regex
//  layer fills the gaps Anitomy doesn't handle well — Western `SxxExx`, movie
//  `Name.Year`, and (importantly) recovering bracketed CJK titles that classic
//  Anitomy leaves out of `anime_title` (ADR-0006).
//
//  Pure function, no IO. Any input yields a non-nil ParsedMedia.

import Foundation
import AnitomyBridge

public struct ParsedMedia: Sendable, Equatable {
    public var title: String
    public var season: Int?
    public var episode: Int?
    public var year: Int?
    public var resolution: String?
    public var releaseGroup: String?
    public var kindHint: MediaKind

    public init(title: String,
                season: Int? = nil,
                episode: Int? = nil,
                year: Int? = nil,
                resolution: String? = nil,
                releaseGroup: String? = nil,
                kindHint: MediaKind) {
        self.title = title
        self.season = season
        self.episode = episode
        self.year = year
        self.resolution = resolution
        self.releaseGroup = releaseGroup
        self.kindHint = kindHint
    }
}

public enum FilenameParser {

    // Pre-compiled once (Phase 1 RssRuleEngine convention) rather than per call.
    private static let bracketRE = try! NSRegularExpression(pattern: "[\\[\\(【（]([^\\]\\)】）]+)[\\]\\)】）]")
    private static let sxxExxRE  = try! NSRegularExpression(pattern: "[Ss](\\d{1,2})[Ee](\\d{1,3})")
    private static let yearRE    = try! NSRegularExpression(pattern: "(?:^|[^\\d])((?:19|20)\\d{2})(?:[^\\d]|$)")
    private static let resolutionRE = try! NSRegularExpression(pattern: "(2160p|1440p|1080p|720p|480p|4k)",
                                                               options: .caseInsensitive)

    public static func parse(_ filename: String) -> ParsedMedia {
        let ant = ANTParser.parse(filename) ?? [:]

        let group      = ant["release_group"].flatMap(nonEmpty)
        let antEpisode = ant["episode_number"].flatMap(firstInt)
        let antSeason  = ant["anime_season"].flatMap(firstInt)
        let antYear    = ant["anime_year"].flatMap { Int($0) }
        let antTitle   = ant["anime_title"].flatMap(nonEmpty)
        // Anitomy misses some resolution spellings (e.g. bare "4K"); back it up
        // with a regex over the raw filename.
        let resolution = ant["video_resolution"].flatMap(nonEmpty).map(normalizeResolution)
            ?? matchResolution(filename)

        let sxx = matchSxxExx(filename)
        let episode = antEpisode ?? sxx?.episode
        let season  = antSeason ?? sxx?.season

        // 1) TV — we have an episode (from Anitomy or SxxExx).
        if let episode {
            let title = antTitle.map(cleanTitle)
                ?? recoverBracketTitle(filename, group: group, episode: episode, resolution: resolution)
                ?? sxx.map { cleanTitle(String(filename[filename.startIndex..<$0.range.lowerBound])) }
                ?? cleanTitle(stripExtension(filename))
            return ParsedMedia(title: nonEmpty(title) ?? stripExtension(filename),
                               season: season, episode: episode, year: antYear,
                               resolution: resolution, releaseGroup: group, kindHint: .tv)
        }

        // 2) Movie — no episode but a year (from Anitomy or regex). Recompute the
        //    title from the part before the regex year so the year isn't left in it.
        let regexYear = matchYear(filename)
        if let year = antYear ?? regexYear?.year {
            let titlePart = regexYear.map { String(filename[filename.startIndex..<$0.range.lowerBound]) }
            let title = titlePart.map(cleanTitle).flatMap(nonEmpty)
                ?? antTitle.map(cleanTitle).flatMap(nonEmpty)
                ?? cleanTitle(stripExtension(filename))
            return ParsedMedia(title: title, season: nil, episode: nil, year: year,
                               resolution: resolution, releaseGroup: group, kindHint: .movie)
        }

        // 3) No episode, no year → can't classify. Keep any title we found.
        let title = antTitle.map(cleanTitle).flatMap(nonEmpty)
            ?? nonEmpty(cleanTitle(stripExtension(filename)))
            ?? filename
        return ParsedMedia(title: title, season: season, episode: nil, year: nil,
                           resolution: resolution, releaseGroup: group, kindHint: .unknown)
    }

    // MARK: - CJK / bracket title recovery

    /// Picks the title from `[a][b][c]…` segments after discarding the ones
    /// Anitomy already identified (group / episode / resolution) and tag-like
    /// noise (language / source / codec markers). Prefers a segment containing
    /// CJK; falls back to the longest remaining segment.
    private static func recoverBracketTitle(_ filename: String, group: String?,
                                            episode: Int, resolution: String?) -> String? {
        let segments = bracketSegments(filename)
        guard !segments.isEmpty else { return nil }

        let candidates = segments.filter { seg in
            let s = seg.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { return false }
            if let group, s.caseInsensitiveCompare(group) == .orderedSame { return false }
            if let resolution, s.lowercased().contains(resolution.lowercased()) { return false }
            if isEpisodeToken(s, episode: episode) { return false }
            if isTagLike(s) { return false }
            return true
        }

        if let cjk = candidates.first(where: containsCJK) {
            return cleanTitle(cjk)
        }
        if let longest = candidates.max(by: { $0.count < $1.count }) {
            return cleanTitle(longest)
        }
        return nil
    }

    private static func bracketSegments(_ s: String) -> [String] {
        // Contents of [...], (...), 【...】, （...）.
        let ns = s as NSString
        return bracketRE.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    private static func isEpisodeToken(_ s: String, episode: Int) -> Bool {
        // "04", "4", "EP04", "第04话" etc. — the segment is just the episode marker.
        let digits = s.filter(\.isNumber)
        return !digits.isEmpty && Int(digits) == episode && s.count <= digits.count + 6
    }

    private static let tagKeywords: Set<String> = [
        "chs", "cht", "sc", "tc", "gb", "big5", "jpsc", "jptc",
        "简", "繁", "日", "简日", "繁日", "简体", "繁体", "简日双语", "繁日双语", "中日双语",
        "webrip", "web-dl", "webdl", "bdrip", "bd", "bluray", "hdtv", "dvdrip", "remux",
        "x264", "x265", "h264", "h265", "hevc", "avc", "aac", "flac", "opus", "ac3",
        "10bit", "8bit", "10-bit", "60fps", "hdr", "ma", "tv",
    ]

    private static func isTagLike(_ s: String) -> Bool {
        let low = s.lowercased().trimmingCharacters(in: .whitespaces)
        if tagKeywords.contains(low) { return true }
        // A segment made only of digits (checksum/episode-ish) or a single short
        // ASCII token that is a known tag.
        if low.allSatisfy({ $0.isHexDigit }) && low.count >= 6 { return true }   // CRC32
        // Resolution-like inside the segment.
        if low.range(of: "\\b(\\d{3,4}p|2160p|4k)\\b", options: .regularExpression) != nil { return true }
        return false
    }

    // MARK: - Regex fallbacks

    private struct SxxExxMatch { let season: Int; let episode: Int; let range: Range<String.Index> }

    private static func matchSxxExx(_ s: String) -> SxxExxMatch? {
        guard let m = sxxExxRE.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range, in: s),
              let sNum = intFrom(s, m.range(at: 1)),
              let eNum = intFrom(s, m.range(at: 2)) else { return nil }
        return SxxExxMatch(season: sNum, episode: eNum, range: r)
    }

    private struct YearMatch { let year: Int; let range: Range<String.Index> }

    private static func matchYear(_ s: String) -> YearMatch? {
        guard let m = yearRE.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let yNum = intFrom(s, m.range(at: 1)),
              let full = Range(m.range, in: s) else { return nil }
        // Use the full match start so the year (and trailing junk) is dropped from title.
        return YearMatch(year: yNum, range: full)
    }

    // MARK: - Helpers

    /// Resolution regex over the whole filename, for spellings Anitomy misses
    /// (notably a bare "4K"). Returns a normalized value or nil.
    private static func matchResolution(_ s: String) -> String? {
        guard let m = resolutionRE.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range, in: s) else { return nil }
        return normalizeResolution(String(s[r]))
    }

    static func normalizeResolution(_ s: String) -> String {
        let low = s.lowercased()
        if low.contains("2160") || low.contains("4k") { return "2160p" }
        if low.contains("1440") { return "1440p" }
        if low.contains("1080") { return "1080p" }
        if low.contains("720")  { return "720p" }
        if low.contains("480")  { return "480p" }
        return low
    }

    private static func cleanTitle(_ raw: String) -> String {
        var t = stripExtension(raw)
        // Drop bracketed/parenthesized tag groups.
        t = t.replacingOccurrences(of: "[\\[\\(【（][^\\]\\)】）]*[\\]\\)】）]",
                                   with: " ", options: .regularExpression)
        // Separators → spaces.
        t = t.replacingOccurrences(of: "[._]", with: " ", options: .regularExpression)
        // Collapse whitespace.
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func stripExtension(_ s: String) -> String {
        let known: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "ts", "flv",
                                  "webm", "wmv", "rmvb"]
        let ext = (s as NSString).pathExtension.lowercased()
        return known.contains(ext) ? (s as NSString).deletingPathExtension : s
    }

    private static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) ||   // Hiragana/Katakana
            (0x4E00...0x9FFF).contains(scalar.value) ||   // CJK Unified
            (0x3400...0x4DBF).contains(scalar.value) ||   // CJK Ext A
            (0xF900...0xFAFF).contains(scalar.value)      // CJK Compatibility
        }
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// First run of digits as an Int (handles "04", "01v2", "第04话").
    private static func firstInt(_ s: String) -> Int? {
        guard let r = s.range(of: "\\d+", options: .regularExpression) else { return nil }
        return Int(s[r])
    }

    private static func intFrom(_ s: String, _ nsRange: NSRange) -> Int? {
        guard let r = Range(nsRange, in: s) else { return nil }
        return Int(s[r])
    }
}

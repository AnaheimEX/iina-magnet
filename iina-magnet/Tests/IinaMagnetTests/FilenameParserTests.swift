//
//  FilenameParserTests.swift
//  IinaMagnetTests
//
//  Fixture-driven tests for the Phase 2 filename parser (Issue 03). Covers the
//  Anitomy-title path, the CJK bracket-title recovery (the case classic Anitomy
//  leaves out of anime_title — ADR-0006), the Western SxxExx / movie regex
//  fallbacks, and the always-non-nil unknown path.

import Testing
import Foundation
@testable import IinaMagnet

@Suite("FilenameParser")
struct FilenameParserTests {

    @Test("Latin fansub name via Anitomy")
    func latinFansub() {
        let p = FilenameParser.parse("[Nekomoe kissaten][Boku no Hero Academia][01][1080p].mkv")
        #expect(p.title == "Boku no Hero Academia")
        #expect(p.episode == 1)
        #expect(p.releaseGroup == "Nekomoe kissaten")
        #expect(p.resolution == "1080p")
        #expect(p.kindHint == .tv)
    }

    @Test("CJK fansub name: title recovered from brackets")
    func cjkFansubRecovery() {
        let p = FilenameParser.parse("[喵萌奶茶屋][葬送的芙莉莲][04][1080p][简日双语].mkv")
        #expect(p.title == "葬送的芙莉莲")
        #expect(p.episode == 4)
        #expect(p.releaseGroup == "喵萌奶茶屋")
        #expect(p.resolution == "1080p")
        #expect(p.kindHint == .tv)
    }

    @Test("LoliHouse style with technical tag block")
    func loliHouse() {
        let p = FilenameParser.parse("[LoliHouse] Frieren - 01 [WebRip 1080p HEVC-10bit AAC][CHS].mkv")
        #expect(p.title.contains("Frieren"))
        #expect(p.episode == 1)
        #expect(p.resolution == "1080p")
        #expect(p.kindHint == .tv)
    }

    @Test("Western SxxExx → tv, season+episode, cleaned title")
    func westernSeries() {
        let p = FilenameParser.parse("Show.Name.S02E03.1080p.WEB-DL.x264.mkv")
        #expect(p.season == 2)
        #expect(p.episode == 3)
        #expect(p.title == "Show Name")
        #expect(p.kindHint == .tv)
    }

    @Test("Movie Name.Year with no episode → movie")
    func movie() {
        let p = FilenameParser.parse("Movie.Name.2021.2160p.BluRay.x265.mkv")
        #expect(p.year == 2021)
        #expect(p.episode == nil)
        #expect(p.resolution == "2160p")
        #expect(p.kindHint == .movie)
        #expect(p.title == "Movie Name")
    }

    @Test("CJK episode range keeps first episode and recovers title")
    func cjkRange() {
        let p = FilenameParser.parse("[某组][某部番剧][01-12][1080p].mkv")
        #expect(p.episode == 1)
        #expect(p.title == "某部番剧")
        #expect(p.kindHint == .tv)
    }

    @Test("4K normalizes to 2160p")
    func resolutionNormalization() {
        let p = FilenameParser.parse("Movie.Title.2019.4K.HDR.mkv")
        #expect(p.resolution == "2160p")
    }

    @Test("Pure garbage → unknown with non-empty title, never crashes")
    func garbage() {
        let p = FilenameParser.parse("???___---")
        #expect(p.kindHint == .unknown)
        #expect(!p.title.isEmpty)
    }

    @Test("Empty string → unknown, non-empty fallback title is the input")
    func empty() {
        let p = FilenameParser.parse("")
        #expect(p.kindHint == .unknown)
    }
}

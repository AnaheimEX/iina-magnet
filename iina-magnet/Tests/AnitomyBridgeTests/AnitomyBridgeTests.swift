//
//  AnitomyBridgeTests.swift
//  AnitomyBridgeTests
//
//  Exercises the Obj-C++ ANTParser over the vendored classic Anitomy (ADR-0006).
//  Pure parsing — no network, no filesystem.

import Testing
import Foundation
@testable import AnitomyBridge

@Suite("AnitomyBridge")
struct AnitomyBridgeTests {

    @Test("Parses a typical fansub release name")
    func fansubName() throws {
        let d = try #require(ANTParser.parse("[Nekomoe kissaten][Boku no Hero Academia][01][1080p].mkv"))
        #expect(d["anime_title"] == "Boku no Hero Academia")
        #expect(d["episode_number"] == "01")
        #expect(d["release_group"] == "Nekomoe kissaten")
        #expect(d["video_resolution"] == "1080p")
        #expect(d["file_extension"]?.lowercased() == "mkv")
    }

    @Test("Western SxxExx + year style still yields a title")
    func westernStyle() throws {
        let d = try #require(ANTParser.parse("Toradora! (2008) - 01v2 [1080p].mkv"))
        #expect(d["anime_title"] == "Toradora!")
        #expect(d["episode_number"] == "01")
        #expect(d["anime_year"] == "2008")
    }

    @Test("CJK content round-trips without mojibake")
    func cjkRoundTrip() throws {
        // An unbracketed CJK title IS recognized as anime_title — proves the
        // UTF-32 ↔ wstring conversion is lossless for CJK.
        let d = try #require(ANTParser.parse("葬送的芙莉莲 04"))
        #expect(d["anime_title"] == "葬送的芙莉莲")
        #expect(d["episode_number"] == "04")
    }

    @Test("CJK fansub name: group/episode/resolution extracted; title gap is Issue 03's job")
    func cjkFansubName() throws {
        // Classic Anitomy reliably pulls group/episode/resolution from a bracketed
        // CJK release, but does NOT promote the bracketed CJK title to anime_title.
        // The bridge faithfully exposes what Anitomy found; FilenameParser (Issue 03)
        // recovers the CJK title heuristically. Locking the contract here.
        let d = try #require(ANTParser.parse("[喵萌奶茶屋][葬送的芙莉莲][04][1080p][简日双语].mkv"))
        #expect(d["release_group"] == "喵萌奶茶屋")
        #expect(d["episode_number"] == "04")
        #expect(d["video_resolution"] == "1080p")
        #expect(d["file_extension"]?.lowercased() == "mkv")
        #expect(d["anime_title"] == nil)   // documents the limitation Issue 03 must cover
    }

    @Test("Empty input parses to nil")
    func emptyInput() {
        #expect(ANTParser.parse("") == nil)
    }

    @Test("Pure punctuation/garbage yields at most a benign result, never crashes")
    func garbage() {
        // Anitomy may extract a degenerate title; the contract is only that it
        // does not crash and returns either nil or a dictionary.
        _ = ANTParser.parse("???___---")
    }
}

//
//  MikanTitleTests.swift
//  IinaMagnetTests
//
//  The pure title-cleaner that turns a Mikan table cell's text into a save name.

import Testing
import Foundation
@testable import IinaMagnet

@Suite struct MikanTitleTests {

    @Test func collapsesWhitespaceAndTrims() {
        let raw = "  [Sakurato]  葬送的芙莉莲  [01]\n\t1080p  "
        #expect(MikanTitle.clean(raw) == "[Sakurato] 葬送的芙莉莲 [01] 1080p")
    }

    @Test func emptyOrWhitespaceBecomesEmpty() {
        #expect(MikanTitle.clean("") == "")
        #expect(MikanTitle.clean("   \n\t ") == "")
    }

    @Test func capsAbsurdlyLongCaptures() {
        let huge = String(repeating: "番", count: 1000)
        #expect(MikanTitle.clean(huge).count == 300)
    }

    @Test func keepsAOrdinaryTitleUnchanged() {
        let title = "[ANi] 药屋少女的呢喃 - 24 [1080P][Baha][WEB-DL][AAC AVC][CHT].mp4"
        #expect(MikanTitle.clean(title) == title)
    }
}

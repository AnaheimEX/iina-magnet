//
//  RssRuleEngineTests.swift
//  IinaMagnetTests
//
//  Pure-function tests for the RSS rule engine.

import Testing
@testable import IinaMagnet

private func rule(id: String = "r1",
                  name: String = "rule",
                  include: [String] = [],
                  exclude: [String] = [],
                  regex: String? = nil,
                  caseSensitive: Bool = false,
                  enabled: Bool = true) -> EngineRule {
    EngineRule(id: id, name: name, include: include, exclude: exclude,
               regex: regex, caseSensitive: caseSensitive, enabled: enabled)
}

private func item(_ title: String, guid: String? = nil) -> EngineFeedItem {
    EngineFeedItem(guid: guid ?? title, title: title)
}

@Suite("RssRuleEngine")
struct RssRuleEngineTests {

    @Test("Empty inputs → empty output")
    func empty() {
        #expect(RssRuleEngine.evaluate(items: [], rules: []).isEmpty)
    }

    @Test("include[] all must match")
    func includeAndSemantics() {
        let r = rule(include: ["1080p", "chs"])
        let items = [item("[Group] Show 01 1080p chs"),
                     item("[Group] Show 02 720p chs"),
                     item("[Group] Show 03 1080p"),
                     item("[Group] Show 04 1080p chs cht")]
        let matches = RssRuleEngine.evaluate(items: items, rules: [r])
        #expect(matches.count == 2)
        #expect(matches.map(\.itemGuid).sorted() ==
                ["[Group] Show 01 1080p chs", "[Group] Show 04 1080p chs cht"])
    }

    @Test("exclude[] any match rejects")
    func excludeRejects() {
        let r = rule(include: ["1080p"], exclude: ["RAW"])
        let items = [item("Show 01 1080p"),
                     item("Show 02 1080p RAW"),
                     item("Show 03 720p")]
        let matches = RssRuleEngine.evaluate(items: items, rules: [r])
        #expect(matches.count == 1)
        #expect(matches.first?.itemGuid == "Show 01 1080p")
    }

    @Test("caseSensitive=false matches CHS / chs / Chs")
    func caseInsensitive() {
        let r = rule(include: ["chs"], caseSensitive: false)
        let items = [item("Show CHS"), item("Show Chs"), item("Show chs")]
        let matches = RssRuleEngine.evaluate(items: items, rules: [r])
        #expect(matches.count == 3)
    }

    @Test("caseSensitive=true matches only exact case")
    func caseSensitive() {
        let r = rule(include: ["CHS"], caseSensitive: true)
        let items = [item("Show CHS"), item("Show chs")]
        let matches = RssRuleEngine.evaluate(items: items, rules: [r])
        #expect(matches.count == 1)
    }

    @Test("regex match")
    func regex() {
        let r = rule(regex: #"S0?1E0[1-3]\b"#)
        let items = [item("Show.S01E01.1080p"),
                     item("Show.S01E02.1080p"),
                     item("Show.S01E10.1080p"),
                     item("Show.S2E01.1080p")]
        let matches = RssRuleEngine.evaluate(items: items, rules: [r])
        #expect(matches.count == 2)
    }

    @Test("Invalid regex returns no match, doesn't crash")
    func invalidRegex() {
        let r = rule(regex: "([unclosed")
        let matches = RssRuleEngine.evaluate(items: [item("any title")], rules: [r])
        #expect(matches.isEmpty)
    }

    @Test("Multiple rules: first enabled match wins, only one match per item")
    func firstRuleWins() {
        let r1 = rule(id: "r1", name: "first", include: ["1080p"])
        let r2 = rule(id: "r2", name: "second", include: ["1080p", "chs"])
        let items = [item("Show 1080p chs")]
        let matches = RssRuleEngine.evaluate(items: items, rules: [r1, r2])
        #expect(matches.count == 1)
        #expect(matches.first?.ruleId == "r1")
    }

    @Test("Disabled rules skipped")
    func disabledSkipped() {
        let r1 = rule(id: "r1", include: ["never"], enabled: false)
        let r2 = rule(id: "r2", include: ["1080p"], enabled: true)
        let matches = RssRuleEngine.evaluate(items: [item("Show 1080p")], rules: [r1, r2])
        #expect(matches.count == 1)
        #expect(matches.first?.ruleId == "r2")
    }

    @Test("Empty include list with non-empty exclude works")
    func emptyIncludeUsesExcludeOnly() {
        let r = rule(include: [], exclude: ["RAW"])
        let items = [item("Show 1080p"), item("Show RAW")]
        let matches = RssRuleEngine.evaluate(items: items, rules: [r])
        #expect(matches.count == 1)
    }
}

//
//  RssRuleEngine.swift
//  IinaMagnet
//
//  Pure-function deep module (Issue 11). Matches FeedItems against
//  SubscriptionRules. Decoupled from SwiftData so it's trivially testable —
//  callers convert their persisted models to EngineRule / EngineFeedItem.

import Foundation

public struct EngineRule: Sendable, Equatable {
    public let id: String                // opaque caller-provided identifier
    public let name: String
    public let include: [String]
    public let exclude: [String]
    public let regex: String?
    public let caseSensitive: Bool
    public let enabled: Bool

    public init(id: String,
                name: String,
                include: [String],
                exclude: [String],
                regex: String?,
                caseSensitive: Bool,
                enabled: Bool) {
        self.id = id
        self.name = name
        self.include = include
        self.exclude = exclude
        self.regex = regex
        self.caseSensitive = caseSensitive
        self.enabled = enabled
    }
}

public struct EngineFeedItem: Sendable, Equatable {
    public let guid: String
    public let title: String

    public init(guid: String, title: String) {
        self.guid = guid
        self.title = title
    }
}

public struct EngineMatch: Sendable, Equatable {
    public let itemGuid: String
    public let ruleId: String
    public let ruleName: String
}

public enum RssRuleEngine {

    /// Apply rules to items. One item produces at most one match — the first
    /// enabled rule (in the input order) that fires wins.
    public static func evaluate(items: [EngineFeedItem], rules: [EngineRule]) -> [EngineMatch] {
        // Pre-compile regexes once; lookup by rule.id.
        var compiled: [String: NSRegularExpression] = [:]
        for rule in rules where rule.enabled {
            guard let pat = rule.regex, !pat.isEmpty else { continue }
            let opts: NSRegularExpression.Options = rule.caseSensitive ? [] : [.caseInsensitive]
            if let re = try? NSRegularExpression(pattern: pat, options: opts) {
                compiled[rule.id] = re
            }
            // Invalid regex → silently treated as never-matching (UI validates earlier).
        }

        var matches: [EngineMatch] = []
        matches.reserveCapacity(items.count)

        for item in items {
            for rule in rules where rule.enabled {
                if matchesRule(item.title, rule: rule, compiled: compiled[rule.id]) {
                    matches.append(EngineMatch(itemGuid: item.guid, ruleId: rule.id, ruleName: rule.name))
                    break   // one match per item
                }
            }
        }
        return matches
    }

    private static func matchesRule(_ title: String, rule: EngineRule, compiled: NSRegularExpression?) -> Bool {
        // Regex mode wins if present
        if let re = compiled {
            let range = NSRange(title.startIndex..<title.endIndex, in: title)
            return re.firstMatch(in: title, options: [], range: range) != nil
        }
        if rule.regex != nil { return false }   // regex set but invalid → never match

        // Keyword mode
        let hay = rule.caseSensitive ? title : title.lowercased()
        let inc = rule.caseSensitive ? rule.include : rule.include.map { $0.lowercased() }
        let exc = rule.caseSensitive ? rule.exclude : rule.exclude.map { $0.lowercased() }

        // include[] is AND-all; empty list = no constraint
        if !inc.isEmpty {
            for needle in inc where !hay.contains(needle) { return false }
        }
        // exclude[] is "any match → reject"
        for needle in exc where hay.contains(needle) { return false }
        return true
    }
}

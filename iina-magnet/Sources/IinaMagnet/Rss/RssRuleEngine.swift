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
        // Precompile per-rule artifacts so the inner loop stays cheap.
        // - Regex compiled once; nil entry == "no regex"
        // - Lowercased keyword arrays cached for case-insensitive rules
        struct CompiledRule {
            let original: EngineRule
            let regex: NSRegularExpression?    // nil if rule has no regex or regex invalid
            let regexInvalid: Bool             // true when rule wanted regex but it failed to compile
            let include: [String]              // case-folded if !caseSensitive
            let exclude: [String]
        }

        let compiledRules: [CompiledRule] = rules.compactMap { rule in
            guard rule.enabled else { return nil }
            var re: NSRegularExpression? = nil
            var regexInvalid = false
            if let pat = rule.regex, !pat.isEmpty {
                let opts: NSRegularExpression.Options = rule.caseSensitive ? [] : [.caseInsensitive]
                if let made = try? NSRegularExpression(pattern: pat, options: opts) {
                    re = made
                } else {
                    regexInvalid = true
                }
            }
            let inc = rule.caseSensitive ? rule.include : rule.include.map { $0.lowercased() }
            let exc = rule.caseSensitive ? rule.exclude : rule.exclude.map { $0.lowercased() }
            return CompiledRule(original: rule, regex: re, regexInvalid: regexInvalid,
                                include: inc, exclude: exc)
        }

        var matches: [EngineMatch] = []
        matches.reserveCapacity(items.count)

        for item in items {
            // Hoist the case-folded title once per item.
            let titleFolded = item.title.lowercased()

            for cr in compiledRules {
                if cr.regex != nil || cr.regexInvalid {
                    // Regex rules (or attempted-regex rules) skip keyword matching entirely.
                    guard let re = cr.regex else { continue }
                    let range = NSRange(item.title.startIndex..<item.title.endIndex, in: item.title)
                    if re.firstMatch(in: item.title, options: [], range: range) != nil {
                        matches.append(EngineMatch(itemGuid: item.guid, ruleId: cr.original.id, ruleName: cr.original.name))
                        break
                    }
                    continue
                }

                // Keyword mode. range(of:options:.literal) avoids Unicode
                // collation that String.contains does by default.
                let hay = cr.original.caseSensitive ? item.title : titleFolded
                if !cr.include.isEmpty {
                    var ok = true
                    for needle in cr.include where hay.range(of: needle, options: .literal) == nil {
                        ok = false; break
                    }
                    if !ok { continue }
                }
                var rejected = false
                for needle in cr.exclude where hay.range(of: needle, options: .literal) != nil {
                    rejected = true; break
                }
                if rejected { continue }

                matches.append(EngineMatch(itemGuid: item.guid, ruleId: cr.original.id, ruleName: cr.original.name))
                break
            }
        }
        return matches
    }
}

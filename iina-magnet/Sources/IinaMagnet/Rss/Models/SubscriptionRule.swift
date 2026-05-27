//
//  SubscriptionRule.swift
//  IinaMagnet
//
//  A filter rule attached to a SubscriptionSource (Issue 10).
//  Either include/exclude keyword lists (default) or a single regex.

import Foundation
import SwiftData

@Model
public final class SubscriptionRule {

    public var name: String
    public var include: [String]
    public var exclude: [String]
    public var regex: String?            // nil = use include/exclude; non-empty = use regex
    public var caseSensitive: Bool
    public var enabled: Bool
    public var hitCount: Int
    public var source: SubscriptionSource?

    public init(name: String,
                include: [String] = [],
                exclude: [String] = [],
                regex: String? = nil,
                caseSensitive: Bool = false,
                enabled: Bool = true) {
        self.name = name
        self.include = include
        self.exclude = exclude
        // Normalize empty regex to nil so the engine doesn't bother compiling.
        if let r = regex, r.trimmingCharacters(in: .whitespaces).isEmpty {
            self.regex = nil
        } else {
            self.regex = regex
        }
        self.caseSensitive = caseSensitive
        self.enabled = enabled
        self.hitCount = 0
    }
}

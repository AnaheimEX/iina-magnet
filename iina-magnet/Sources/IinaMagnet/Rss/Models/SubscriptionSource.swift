//
//  SubscriptionSource.swift
//  IinaMagnet
//
//  One configured RSS feed (Issue 10). Has URL, polling cadence, optional
//  auth headers (for sources like mikanani.me/MyBangumi that need cookies),
//  and a 1-N relationship to SubscriptionRule.

import Foundation
import SwiftData

public enum PollResult: Codable, Sendable, Equatable {
    case success(itemCount: Int)
    case error(message: String)
}

@Model
public final class SubscriptionSource {

    @Attribute(.unique) public var url: URL
    public var displayName: String
    public var pollIntervalSeconds: Int                 // default 1800 (30 min)
    public var cookieHeader: String?
    public var customHeaders: [String: String]
    public var enabled: Bool
    @Relationship(deleteRule: .cascade, inverse: \SubscriptionRule.source)
    public var rules: [SubscriptionRule] = []
    public var lastPolledAt: Date?
    public var lastPollResult: PollResult?

    public init(url: URL,
                displayName: String,
                pollIntervalSeconds: Int = 1800,
                cookieHeader: String? = nil,
                customHeaders: [String: String] = [:],
                enabled: Bool = true) {
        self.url = url
        self.displayName = displayName
        self.pollIntervalSeconds = pollIntervalSeconds
        self.cookieHeader = cookieHeader
        self.customHeaders = customHeaders
        self.enabled = enabled
    }
}

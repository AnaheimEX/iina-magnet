//
//  FeedItem.swift
//  IinaMagnet
//
//  One parsed RSS / Atom entry. Used for dedup history (guid unique) and as
//  the source for rule matching. Linked to its SubscriptionSource via a
//  @Relationship; SwiftData rejects raw PersistentIdentifier as a stored attr.

import Foundation
import SwiftData

@Model
public final class FeedItem {

    @Attribute(.unique) public var guid: String
    public var title: String
    public var enclosureURL: URL
    public var publishedAt: Date
    public var source: SubscriptionSource?
    public var matched: Bool
    public var matchedRule: SubscriptionRule?
    public var firstSeenAt: Date

    public init(guid: String,
                title: String,
                enclosureURL: URL,
                publishedAt: Date,
                source: SubscriptionSource? = nil) {
        self.guid = guid
        self.title = title
        self.enclosureURL = enclosureURL
        self.publishedAt = publishedAt
        self.source = source
        self.matched = false
        self.matchedRule = nil
        self.firstSeenAt = .now
    }
}

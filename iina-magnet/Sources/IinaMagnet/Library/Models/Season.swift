//
//  Season.swift
//  IinaMagnet
//
//  A season of a TV/anime Title (Phase 2, Issue 01). Movies use a placeholder
//  Season(number: 0) so VersionFiles always hang off an Episode uniformly.

import Foundation
import SwiftData

@Model
public final class Season {

    public var number: Int
    public var title: Title?

    @Relationship(deleteRule: .cascade, inverse: \Episode.season)
    public var episodes: [Episode] = []

    public init(number: Int) {
        self.number = number
    }
}

//
//  Tag.swift
//  IinaMagnet
//
//  A label on a Title (Phase 2, Issue 01). Auto-derived (genre/year/country/
//  quality/ratingBucket/releaseGroup) by TagDeriver (Issue 12) or user-defined.
//  Many-to-many with Title; the inverse lives on Title.tags.

import Foundation
import SwiftData

@Model
public final class Tag {

    public var name: String
    public var categoryRaw: Int        // TagCategory.rawValue

    public var titles: [Title] = []    // inverse of Title.tags

    public var category: TagCategory {
        get { TagCategory(rawValue: categoryRaw) ?? .userDefined }
        set { categoryRaw = newValue.rawValue }
    }

    public init(name: String, category: TagCategory) {
        self.name = name
        self.categoryRaw = category.rawValue
    }
}

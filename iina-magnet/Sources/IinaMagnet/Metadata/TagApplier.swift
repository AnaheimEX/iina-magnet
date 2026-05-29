//
//  TagApplier.swift
//  IinaMagnet
//
//  Persists DerivedTags onto a Title: find-or-create each Tag (so tags are
//  shared, many-to-many) and attach it without duplicating an existing link.
//  Shared by the Ingester (first ingest) and LibraryEditor (manual re-match).

import Foundation
import SwiftData

public enum TagApplier {

    /// Attaches the derived tags to `title`, find-or-creating each shared Tag.
    public static func apply(_ derived: [DerivedTag], to title: Title,
                             context: ModelContext) throws {
        for d in derived {
            let tag = try findOrCreate(name: d.name, category: d.category, context: context)
            if !title.tags.contains(where: { $0.name == tag.name && $0.category == tag.category }) {
                title.tags.append(tag)
            }
        }
    }

    public static func findOrCreate(name: String, category: TagCategory,
                                    context: ModelContext) throws -> Tag {
        let catRaw = category.rawValue
        var d = FetchDescriptor<Tag>(predicate: #Predicate { $0.name == name && $0.categoryRaw == catRaw })
        d.fetchLimit = 1
        if let found = try context.fetch(d).first { return found }
        let t = Tag(name: name, category: category)
        context.insert(t)
        return t
    }
}

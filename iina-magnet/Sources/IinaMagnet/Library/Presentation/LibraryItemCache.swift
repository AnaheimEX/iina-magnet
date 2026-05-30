//
//  LibraryItemCache.swift
//  IinaMagnet
//
//  Memoizes Title → LibraryItemViewModel so the browser doesn't rebuild every
//  card's view model (each of which walks the whole season/episode/version tree)
//  on every SwiftUI render. A VM is reused while its Title's `updatedAt` is
//  unchanged — and every write path bumps `updatedAt`, so the cache invalidates
//  exactly when the data changes. Entries for removed Titles are evicted.

import Foundation
import SwiftData

public final class LibraryItemCache {

    private struct Entry { let updatedAt: Date; let item: LibraryItemViewModel }
    private var entries: [PersistentIdentifier: Entry] = [:]

    public init() {}

    /// View models for `titles`, rebuilding only those whose `updatedAt` changed.
    public func items(for titles: [Title]) -> [LibraryItemViewModel] {
        var next: [PersistentIdentifier: Entry] = [:]
        next.reserveCapacity(titles.count)
        let result = titles.map { title -> LibraryItemViewModel in
            let id = title.persistentModelID
            if let cached = entries[id], cached.updatedAt == title.updatedAt {
                next[id] = cached
                return cached.item
            }
            let item = LibraryItemViewModel(title)
            next[id] = Entry(updatedAt: title.updatedAt, item: item)
            return item
        }
        entries = next   // evict VMs for titles no longer present
        return result
    }
}

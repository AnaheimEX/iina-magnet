//
//  Episode.swift
//  IinaMagnet
//
//  An episode within a Season (Phase 2, Issue 01). `seasonNumber` is denormalized
//  for cheap queries / WatchProgress keying without walking the relationship.
//  Movies use a placeholder Episode(number: 0, seasonNumber: 0).

import Foundation
import SwiftData

@Model
public final class Episode {

    public var number: Int
    public var seasonNumber: Int        // denormalized copy of season.number
    public var title: String?           // localized (zh) title
    public var titleOriginal: String?   // original-language (ja/en) title, shown beneath `title`
    public var airDate: Date?
    public var overview: String?
    public var thumbnailURL: URL?       // 16:9 still; nil → UI falls back to episode number on a gradient

    public var season: Season?

    @Relationship(deleteRule: .cascade, inverse: \VersionFile.episode)
    public var versions: [VersionFile] = []

    public init(number: Int,
                seasonNumber: Int,
                title: String? = nil,
                titleOriginal: String? = nil,
                airDate: Date? = nil,
                overview: String? = nil,
                thumbnailURL: URL? = nil) {
        self.number = number
        self.seasonNumber = seasonNumber
        self.title = title
        self.titleOriginal = titleOriginal
        self.airDate = airDate
        self.overview = overview
        self.thumbnailURL = thumbnailURL
    }
}

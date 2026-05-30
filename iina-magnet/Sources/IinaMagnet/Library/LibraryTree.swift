//
//  LibraryTree.swift
//  IinaMagnet
//
//  Find-or-create helpers for the Title → Season → Episode tree, shared by the
//  Ingester (first ingest) and LibraryEditor (re-bind / file migration) so both
//  build the hierarchy the same way. New nodes are auto-inserted via their
//  relationship to an already-inserted parent.

import Foundation

enum LibraryTree {

    static func season(number: Int, in title: Title) -> Season {
        if let s = title.seasons.first(where: { $0.number == number }) { return s }
        let s = Season(number: number)
        s.title = title
        title.seasons.append(s)
        return s
    }

    static func episode(number: Int, seasonNumber: Int, in season: Season) -> Episode {
        if let e = season.episodes.first(where: { $0.number == number }) { return e }
        let e = Episode(number: number, seasonNumber: seasonNumber)
        e.season = season
        season.episodes.append(e)
        return e
    }
}

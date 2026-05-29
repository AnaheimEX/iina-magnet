//
//  MetadataApplier.swift
//  IinaMagnet
//
//  The single place that copies a resolved MetadataDetails onto a Title's
//  fields. Used by the Ingester (first ingest) and by LibraryEditor (manual
//  re-match), so both agree on field precedence and on which rating scalar a
//  source's score lands in.

import Foundation

public enum MetadataApplier {

    /// Copies `details` onto `title`, preferring metadata values but never
    /// clobbering an existing value with nil. Caller supplies the resulting
    /// match state/score (ingest derives it from the resolution; a manual
    /// re-match passes .confirmed / 1.0).
    public static func apply(_ details: MetadataDetails, to title: Title,
                             matchState: MatchState, matchScore: Double) {
        if details.providerId == .bangumi, let bid = Int(details.externalId) {
            title.bangumiId = bid
        }
        title.titleZh = details.titleZh ?? title.titleZh
        title.titleJa = details.titleJa ?? title.titleJa
        title.titleEn = details.titleEn ?? title.titleEn
        title.overview = details.overview ?? title.overview
        title.posterURL = details.posterURL ?? title.posterURL
        title.releaseYear = details.releaseYear ?? title.releaseYear
        title.runtimeMinutes = details.runtimeMinutes ?? title.runtimeMinutes
        // Store the rating under its source's scalar so the UI can badge provenance.
        if let rating = details.rating {
            switch details.providerId {
            case .bangumi: title.bangumiRating = rating
            case .tmdb:    title.tmdbRating = rating
            case .douban:  title.doubanRating = rating
            // bangumi/tmdb/douban all use a 0–10 scale. Anilist scores 0–100 and
            // has no scalar on Title yet — when it's added, normalize to 0–10 here
            // (and before passing to TagDeriver) rather than storing the raw score.
            case .anilist: break
            }
        }
        title.matchState = matchState
        title.matchScore = matchScore
        title.updatedAt = .now
    }
}

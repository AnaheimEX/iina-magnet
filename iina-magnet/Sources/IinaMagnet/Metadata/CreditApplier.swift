//
//  CreditApplier.swift
//  IinaMagnet
//
//  Applies cast credits (声优 / 角色) from resolved metadata onto a Title.
//  Shared by the Ingester (first ingest) and LibraryEditor (re-match). Replaces
//  any existing credits so a re-match refreshes them cleanly; a source with no
//  cast leaves the existing credits untouched.

import Foundation
import SwiftData

public enum CreditApplier {

    public static func apply(_ cast: [MetadataCast], to title: Title, context: ModelContext) {
        guard !cast.isEmpty else { return }   // don't wipe existing cast on a cast-less source

        for old in title.credits { context.delete(old) }
        title.credits.removeAll()

        for (i, c) in cast.enumerated() {
            let credit = Credit(actorName: c.actor, characterName: c.character, order: i)
            credit.title = title
            title.credits.append(credit)
            context.insert(credit)
        }
    }
}

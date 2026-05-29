//
//  Title+ViewModel.swift
//  IinaMagnet
//
//  Builds a LibraryItemViewModel from a Title, walking its seasons/episodes/
//  versions and its in-progress WatchProgress. This is the one place that
//  touches SwiftData relationships; the resulting value type is pure + Sendable
//  so the SwiftUI views (and their previews/tests) never hold a model.

import Foundation

extension LibraryItemViewModel {

    public init(_ title: Title) {
        self.id = title.persistentModelID
        self.kind = title.kind
        // A title should always have *some* zh label after ingest; fall back to
        // the best original or a placeholder so the card never renders blank.
        self.titleZh = title.titleZh
            ?? title.titleJa
            ?? title.titleEn
            ?? "未命名"
        self.titleOriginal = title.titleJa ?? title.titleEn
        self.year = title.releaseYear
        self.ratings = TitleDerivations.ratings(of: title)
        self.aggregateState = title.aggregateState
        self.matchState = title.matchState
        self.runtimeMinutes = title.runtimeMinutes
        self.posterURL = title.posterURL
        self.tags = title.tags.map { TagRef(name: $0.name, category: $0.category) }

        // Walk versions once for count / top quality / file totals.
        let allVersions = title.seasons.flatMap { $0.episodes.flatMap(\.versions) }
        let present = allVersions.filter { !$0.isMissing }
        self.fileCount = present.count
        self.totalSizeBytes = present.reduce(0) { $0 + $1.fileSizeBytes }
        // Design's "版本数": the most versions any single episode/film has.
        self.versionCount = title.seasons
            .flatMap(\.episodes)
            .map(\.versions.count)
            .max() ?? 0
        self.topQuality = TitleDerivations.topQuality(of: present)
        self.rawName = title.kind == .unknown
            ? present.first?.fileURL.lastPathComponent
            : nil

        self.addedAt = title.createdAt
        self.resume = TitleDerivations.resume(of: title)
    }
}

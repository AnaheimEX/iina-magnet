//
//  ArchiveViewModel.swift
//  IinaMagnet
//
//  Display-ready projection of a Title for the archive/detail page (design
//  Archive.jsx): hero, summary + tags, cast, seasons → episodes (with per-episode
//  watch state + versions), and the movie version list. Three variants fall out
//  of `kind`: tv (seasons), movie (movieVersions, runtime), unknown (rawName +
//  fileInfo + neutral hero). Pure value type; built once from a Title.

import Foundation
import SwiftData

public struct CastMember: Equatable, Sendable, Identifiable {
    public let id: Int          // position
    public let name: String
    public let role: String?
}

public struct ArchiveVersion: Equatable, Sendable, Identifiable {
    public let id: String       // file fingerprint
    public let quality: String?
    public let releaseGroup: String?
    public let languages: [String]
    public let sizeText: String
    public let isMissing: Bool
}

public struct ArchiveEpisode: Equatable, Sendable, Identifiable {
    public let id: Int          // episode number
    public let number: Int
    public let titleZh: String?
    public let titleOriginal: String?
    public let airDateText: String?
    public let thumbnailURL: URL?
    public let state: ProgressState
    public let progress: Double
    public let versions: [ArchiveVersion]
}

public struct ArchiveSeason: Equatable, Sendable, Identifiable {
    public let id: Int          // season number
    public let name: String
    public let episodes: [ArchiveEpisode]
}

public struct FileInfo: Equatable, Sendable {
    public let fileCount: Int
    public let totalSizeText: String
    public let folder: String?
}

public struct ArchiveViewModel: Identifiable, Sendable {
    public let id: PersistentIdentifier
    public let kind: MediaKind
    public let titleZh: String
    public let titleOriginal: String?
    public let rawName: String?
    public let year: Int?
    public let runtimeMinutes: Int?
    public let ratings: [RatingBadge]
    public let overview: String?
    public let posterURL: URL?
    public let backdropURL: URL?
    public let tagNames: [String]
    public let matchState: MatchState
    public let matchScore: Double
    public let cast: [CastMember]            // empty until the persons API lands
    public let seasons: [ArchiveSeason]      // tv / unknown
    public let movieVersions: [ArchiveVersion]
    public let totalEpisodes: Int
    public let bestQuality: String?
    public let resume: ResumeInfo?

    public var isUnmatched: Bool { kind == .unknown || matchState == .unmatched }

    public init(_ title: Title) {
        self.id = title.persistentModelID
        self.kind = title.kind
        self.titleZh = title.titleZh ?? title.titleJa ?? title.titleEn ?? "未命名"
        self.titleOriginal = title.titleJa ?? title.titleEn
        self.year = title.releaseYear
        self.runtimeMinutes = title.runtimeMinutes
        self.ratings = TitleDerivations.ratings(of: title)
        self.overview = title.overview
        self.posterURL = title.posterURL
        self.backdropURL = title.backdropURL
        self.tagNames = title.tags.map(\.name)
        self.matchState = title.matchState
        self.matchScore = title.matchScore
        self.cast = title.credits
            .sorted { $0.order < $1.order }
            .map { CastMember(id: $0.order, name: $0.actorName, role: $0.characterName) }
        self.resume = TitleDerivations.resume(of: title)

        let allVersions = title.seasons.flatMap { $0.episodes.flatMap(\.versions) }
        self.rawName = title.kind == .unknown
            ? allVersions.first(where: { !$0.isMissing })?.fileURL.lastPathComponent
                ?? allVersions.first?.fileURL.lastPathComponent
            : nil

        let progress = TitleDerivations.progressByEpisode(of: title)
        let orderedSeasons = title.seasons.sorted { $0.number < $1.number }

        // Movies hang versions off a season-0/ep-0 placeholder; surface those
        // directly and don't render a season/episode grid.
        if title.kind == .movie {
            let films = orderedSeasons.flatMap(\.episodes).flatMap(\.versions)
            self.movieVersions = films.map(Self.version)
            self.seasons = []
        } else {
            self.movieVersions = []
            self.seasons = orderedSeasons.map { season in
                let eps = season.episodes.sorted { $0.number < $1.number }.map { ep -> ArchiveEpisode in
                    let wp = progress[.init(season: season.number, episode: ep.number)]
                    return ArchiveEpisode(
                        id: ep.number,
                        number: ep.number,
                        titleZh: ep.title,
                        titleOriginal: ep.titleOriginal,
                        airDateText: ep.airDate.map(Self.dateText),
                        thumbnailURL: ep.thumbnailURL,
                        state: wp?.state ?? .unseen,
                        progress: wp.map {
                            LibraryFormatting.progress(positionSec: $0.lastPositionSec,
                                                       durationSec: $0.durationSec)
                        } ?? 0,
                        versions: ep.versions.map(Self.version))
                }
                return ArchiveSeason(id: season.number,
                                     name: Self.seasonName(number: season.number, kind: title.kind),
                                     episodes: eps)
            }
        }

        self.totalEpisodes = kind == .movie ? 0
            : seasons.reduce(0) { $0 + $1.episodes.count }

        let relevant = (title.kind == .movie ? movieVersions : seasons.flatMap(\.episodes).flatMap(\.versions))
            .filter { !$0.isMissing }
        self.bestQuality = relevant
            .compactMap(\.quality)
            .max { TitleDerivations.qualityRank($0) < TitleDerivations.qualityRank($1) }
    }

    /// File summary for the unmatched variant.
    public func fileInfo(from title: Title) -> FileInfo {
        let files = title.seasons.flatMap(\.episodes).flatMap(\.versions)
        let present = files.filter { !$0.isMissing }
        let total = present.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        return FileInfo(fileCount: present.count,
                        totalSizeText: LibraryFormatting.size(total),
                        folder: present.first?.fileURL.deletingLastPathComponent().path)
    }

    // MARK: - Builders

    private static func version(_ v: VersionFile) -> ArchiveVersion {
        ArchiveVersion(id: v.fileFingerprint,
                       quality: v.resolution,
                       releaseGroup: v.releaseGroup,
                       languages: v.languages,
                       sizeText: LibraryFormatting.size(v.fileSizeBytes),
                       isMissing: v.isMissing)
    }

    private static func seasonName(number: Int, kind: MediaKind) -> String {
        if number == 0 { return kind == .unknown ? "未分季" : "正片" }
        return "第\(number)季"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static func dateText(_ date: Date) -> String { dateFormatter.string(from: date) }
}

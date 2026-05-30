//
//  ArchiveView.swift
//  IinaMagnet
//
//  The work archive/detail page (design Archive.jsx): hero + confirm banner +
//  synopsis + (unmatched) file info + cast + episode grid (season switch) +
//  version switch. Three variants fall out of `vm.kind` / `vm.isUnmatched`.
//  Driven by an ArchiveViewModel + action closures wired to LibraryEditor.

import SwiftUI

public struct ArchiveView: View {
    private let vm: ArchiveViewModel
    private let fileInfo: FileInfo?
    private let onBack: () -> Void
    private let onPlay: (ArchiveVersion) -> Void
    private let onReveal: (ArchiveVersion) -> Void
    private let onConfirm: () -> Void
    private let onMarkUnmatched: () -> Void
    private let onMatchSheet: () -> Void
    private let onToggleWatched: (Bool) -> Void

    public init(vm: ArchiveViewModel,
                fileInfo: FileInfo? = nil,
                onBack: @escaping () -> Void = {},
                onPlay: @escaping (ArchiveVersion) -> Void = { _ in },
                onReveal: @escaping (ArchiveVersion) -> Void = { _ in },
                onConfirm: @escaping () -> Void = {},
                onMarkUnmatched: @escaping () -> Void = {},
                onMatchSheet: @escaping () -> Void = {},
                onToggleWatched: @escaping (Bool) -> Void = { _ in }) {
        self.vm = vm
        self.fileInfo = fileInfo
        self.onBack = onBack
        self.onPlay = onPlay
        self.onReveal = onReveal
        self.onConfirm = onConfirm
        self.onMarkUnmatched = onMarkUnmatched
        self.onMatchSheet = onMatchSheet
        self.onToggleWatched = onToggleWatched
    }

    @State private var seasonIdx = 0
    @State private var selectedEpisode = 0
    @State private var selectedVersion: String?   // version id
    @State private var expanded = false

    private var season: ArchiveSeason? {
        vm.seasons.indices.contains(seasonIdx) ? vm.seasons[seasonIdx] : nil
    }
    private var currentEpisode: ArchiveEpisode? {
        season?.episodes.first { $0.number == selectedEpisode }
    }
    private var versions: [ArchiveVersion] {
        vm.kind == .movie ? vm.movieVersions : (currentEpisode?.versions ?? [])
    }
    /// The version the play button acts on: the explicit selection, else the
    /// first present (highest-resolution, since versions are pre-sorted) copy.
    private var selectedVersionObject: ArchiveVersion? {
        versions.first { $0.id == selectedVersion } ?? versions.first { !$0.isMissing }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                confirmBanner
                synopsis
                fileInfoSection
                castSection
                episodesSection
                versionSection
            }
        }
        .background(LibraryTokens.bg)
        .overlay(alignment: .topLeading) { backButton }
        .onAppear(perform: selectDefaults)
    }

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 3) { Image(systemName: "chevron.left"); Text("媒体库") }
                .font(.system(size: 12)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain).padding(12)
    }

    // MARK: Hero

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if vm.isUnmatched {
                    LinearGradient(colors: [Color(white: 0.29), Color(white: 0.14)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                } else if let url = vm.backdropURL {
                    AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fill) }
                        placeholder: { PosterGradient.gradient(seed: vm.titleOriginal ?? vm.titleZh) }
                } else {
                    PosterGradient.gradient(seed: vm.titleOriginal ?? vm.titleZh)
                }
            }
            .frame(height: 320).clipped()
            .overlay(LinearGradient(colors: [.clear, .black.opacity(0.7)],
                                    startPoint: .center, endPoint: .bottom))

            HStack(alignment: .bottom, spacing: 18) {
                posterThumb
                heroMeta
            }
            .padding(20)
        }
    }

    private var posterThumb: some View {
        ZStack {
            if vm.isUnmatched {
                LibraryTokens.bg3
                Image(systemName: "questionmark.folder").font(.system(size: 30))
                    .foregroundStyle(LibraryTokens.text3)
            } else if let url = vm.posterURL {
                AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fill) }
                    placeholder: { PosterGradient.gradient(seed: vm.titleZh) }
            } else {
                PosterGradient.gradient(seed: vm.titleZh)
                Text(vm.titleZh).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(3).padding(8).multilineTextAlignment(.center)
            }
        }
        .frame(width: 124, height: 186)
        .clipShape(RoundedRectangle(cornerRadius: LibraryTokens.Radius.poster))
        .shadow(radius: 12, y: 6)
    }

    private var heroMeta: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(vm.titleZh).font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                .lineLimit(2)
            if let original = vm.titleOriginal {
                Text(original).font(.system(size: 14)).foregroundStyle(.white.opacity(0.8))
            }
            if vm.isUnmatched, let raw = vm.rawName {
                Text(raw).font(.system(size: 12).monospaced()).foregroundStyle(.white.opacity(0.7))
            }
            metaRow
            heroActions.padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            if let y = vm.year { Text(String(y)).monospacedDigit() }
            Text(vm.kind.displayLabel)
            if vm.kind == .movie, let r = vm.runtimeMinutes { Text("\(r) 分钟") }
            if !vm.seasons.isEmpty { Text("共 \(vm.totalEpisodes) 集") }
            if let q = vm.bestQuality {
                Text(q).font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            if !vm.ratings.isEmpty { RatingBadgesView(ratings: vm.ratings, onGlass: true) }
        }
        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.9))
    }

    private var heroActions: some View {
        HStack(spacing: 10) {
            Button(action: playPrimary) {
                HStack(spacing: 5) {
                    Image(systemName: vm.isUnmatched ? "magnifyingglass" : "play.fill")
                    Text(vm.isUnmatched ? "搜索匹配" : (vm.resume?.label ?? "播放"))
                }
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.white, in: Capsule()).foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .disabled(!vm.isUnmatched && selectedVersionObject == nil)

            if !vm.isUnmatched {
                let watched = vm.aggregateState == .completed
                Button { onToggleWatched(!watched) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: watched ? "checkmark.circle.fill" : "checkmark")
                        Text(watched ? "标记未看" : "标记已看")
                    }
                    .font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule()).foregroundStyle(.white)
                }.buttonStyle(.plain)
            }
        }
    }

    // MARK: Confirm banner

    @ViewBuilder
    private var confirmBanner: some View {
        switch vm.matchState {
        case .pendingConfirmation:
            banner(icon: "exclamationmark.triangle.fill",
                   title: "匹配可能有误",
                   detail: "根据文件名识别为《\(vm.titleZh)》" +
                           (vm.titleOriginal.map { "（\($0)）" } ?? "") +
                           " · 置信度 \(Int(vm.matchScore * 100))%。请确认或重新匹配。") {
                bannerButton("确认", prominent: true, action: onConfirm)
                bannerButton("重新匹配", action: onMatchSheet)
                bannerButton("标为未识别", action: onMarkUnmatched)
            }
        case .unmatched:
            banner(icon: "questionmark.circle.fill",
                   title: "未能识别此作品",
                   detail: "未在 bangumi.tv / TMDB 找到匹配。可手动搜索，或保留为未识别媒体。") {
                bannerButton("手动搜索匹配", prominent: true, action: onMatchSheet)
                bannerButton("保留未识别", action: onMarkUnmatched)
            }
        case .confirmed:
            EmptyView()
        }
    }

    private func banner<Actions: View>(icon: String, title: String, detail: String,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(LibraryTokens.warn).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(LibraryTokens.text)
                Text(detail).font(.system(size: 12)).foregroundStyle(LibraryTokens.text2)
                HStack(spacing: 8) { actions() }.padding(.top, 4)
            }
            Spacer()
        }
        .padding(14).background(LibraryTokens.warnSoft)
        .padding(.horizontal, LibraryTokens.Spacing.pagePadding).padding(.top, 16)
    }

    private func bannerButton(_ label: String, prominent: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .font(.system(size: 12))
            .buttonStyle(.bordered)
            .tint(prominent ? LibraryTokens.warn : LibraryTokens.text3)
    }

    // MARK: Synopsis

    @ViewBuilder
    private var synopsis: some View {
        if let overview = vm.overview, !overview.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(overview).font(.system(size: 13)).foregroundStyle(LibraryTokens.text2)
                    .lineLimit(expanded ? nil : 3)
                if overview.count > 60 {
                    Button(expanded ? "收起" : "展开") { expanded.toggle() }
                        .font(.system(size: 12)).buttonStyle(.plain)
                        .foregroundStyle(LibraryTokens.accent)
                }
                if !vm.tagNames.isEmpty { tagRow }
            }
            .padding(.horizontal, LibraryTokens.Spacing.pagePadding).padding(.top, 18)
        }
    }

    private var tagRow: some View {
        LibraryFlowLayout(spacing: 7) {
            ForEach(vm.tagNames, id: \.self) { t in
                Text(t).font(.system(size: 11)).foregroundStyle(LibraryTokens.text2)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(LibraryTokens.fill, in: Capsule())
            }
        }
    }

    // MARK: File info (unmatched)

    @ViewBuilder
    private var fileInfoSection: some View {
        if vm.isUnmatched, let info = fileInfo {
            section(title: "文件信息") {
                HStack(spacing: 12) {
                    Image(systemName: "doc").foregroundStyle(LibraryTokens.text3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.rawName ?? "—").font(.system(size: 12).monospaced())
                            .foregroundStyle(LibraryTokens.text)
                        if let folder = info.folder {
                            Text(folder).font(.system(size: 11)).foregroundStyle(LibraryTokens.text3)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Text("\(info.fileCount) 文件 · \(info.totalSizeText)")
                        .font(.system(size: 12)).foregroundStyle(LibraryTokens.text2)
                }
                .padding(12).background(LibraryTokens.bg2, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: Cast (演职员) — only when the source provided it

    @ViewBuilder
    private var castSection: some View {
        if !vm.cast.isEmpty {
            section(title: "演职员", count: vm.cast.count) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(vm.cast) { member in
                            VStack(spacing: 6) {
                                ZStack {
                                    PosterGradient.gradient(seed: member.name)
                                    Text(member.name.prefix(2))
                                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                }
                                .frame(width: 56, height: 56).clipShape(Circle())
                                Text(member.name).font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(LibraryTokens.text).lineLimit(1)
                                if let role = member.role {
                                    Text(role).font(.system(size: 11)).foregroundStyle(LibraryTokens.text3)
                                        .lineLimit(1)
                                }
                            }
                            .frame(width: 72)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: Episodes

    @ViewBuilder
    private var episodesSection: some View {
        if !vm.seasons.isEmpty {
            section(title: vm.isUnmatched ? "文件" : "剧集", count: vm.totalEpisodes) {
                if vm.seasons.count > 1 {
                    Picker("", selection: $seasonIdx) {
                        ForEach(Array(vm.seasons.enumerated()), id: \.offset) { i, s in
                            Text(s.name).tag(i)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .padding(.bottom, 8)
                    .onChange(of: seasonIdx) { _, _ in selectDefaultEpisode() }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(season?.episodes ?? []) { ep in
                        EpisodeCardView(episode: ep, kind: vm.kind,
                                        selected: ep.number == selectedEpisode) {
                            selectedEpisode = ep.number
                            selectedVersion = ep.versions.first { !$0.isMissing }?.id
                        }
                    }
                }
            }
        }
    }

    // MARK: Versions

    @ViewBuilder
    private var versionSection: some View {
        if !versions.isEmpty {
            section(title: "版本切换",
                    countText: vm.kind == .movie ? "\(versions.count) 个文件"
                        : currentEpisode.map { "第\($0.number)集 · \(versions.count) 个文件" }) {
                if versions.count > 1 {
                    Label("切换版本不影响观看进度——集级进度在所有版本间共享。",
                          systemImage: "info.circle")
                        .font(.system(size: 12)).foregroundStyle(LibraryTokens.text2)
                        .padding(.bottom, 4)
                }
                VStack(spacing: 6) {
                    ForEach(versions) { v in
                        VersionRowView(version: v, selected: v.id == selectedVersion,
                                       onSelect: { if !v.isMissing { selectedVersion = v.id } },
                                       onPlay: { onPlay(v) },
                                       onReveal: { onReveal(v) })
                    }
                }
            }
            .padding(.bottom, 36)
        }
    }

    // MARK: Helpers

    private func section<Content: View>(title: String, count: Int? = nil, countText: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(LibraryTokens.text)
                if let count { Text("\(count)").font(.system(size: 12)).foregroundStyle(LibraryTokens.text3) }
                if let countText { Text(countText).font(.system(size: 12)).foregroundStyle(LibraryTokens.text3) }
            }
            content()
        }
        .padding(.horizontal, LibraryTokens.Spacing.pagePadding).padding(.top, 22)
    }

    private func selectDefaults() {
        if vm.kind == .movie {
            // No episode grid; default to the best present movie version.
            selectedVersion = vm.movieVersions.first { !$0.isMissing }?.id
        } else {
            selectDefaultEpisode()
        }
    }

    /// Default to the resume episode → else first multi-version episode → else first.
    private func selectDefaultEpisode() {
        guard let eps = season?.episodes, !eps.isEmpty else { return }
        let ep = eps.first { $0.state == .inProgress }
            ?? eps.first { $0.versions.count > 1 }
            ?? eps[0]
        selectedEpisode = ep.number
        selectedVersion = ep.versions.first { !$0.isMissing }?.id
    }

    /// Hero primary button: search-match for unmatched works, else play the
    /// selected version.
    private func playPrimary() {
        if vm.isUnmatched { onMatchSheet() }
        else if let version = selectedVersionObject { onPlay(version) }
    }
}

// MARK: - Episode card

struct EpisodeCardView: View {
    let episode: ArchiveEpisode
    let kind: MediaKind
    let selected: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                ZStack {
                    if let url = episode.thumbnailURL {
                        AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fill) }
                            placeholder: { LibraryTokens.bg3 }
                    } else {
                        LibraryTokens.bg3
                        Text("\(episode.number)").font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(LibraryTokens.text3)
                    }
                    if episode.state == .completed {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white).padding(4).background(LibraryTokens.done, in: Circle())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(4)
                    }
                    if episode.state == .inProgress, episode.progress > 0 {
                        VStack { Spacer()
                            ProgressView(value: episode.progress).tint(LibraryTokens.accent)
                                .scaleEffect(x: 1, y: 0.5, anchor: .bottom)
                        }
                    }
                }
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(kind == .unknown ? "文件 \(episode.number)" : "第\(episode.number)集")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(LibraryTokens.text)
                        if episode.versions.count > 1 {
                            Text("\(episode.versions.count) 版本").font(.system(size: 10))
                                .foregroundStyle(LibraryTokens.text3)
                        }
                    }
                    if let t = episode.titleZh ?? episode.titleOriginal {
                        Text(t).font(.system(size: 11)).foregroundStyle(LibraryTokens.text2).lineLimit(1)
                    }
                    if let air = episode.airDateText {
                        Text(air).font(.system(size: 10)).foregroundStyle(LibraryTokens.text3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(selected ? LibraryTokens.accentSoft : LibraryTokens.bg2,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? LibraryTokens.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Version row

struct VersionRowView: View {
    let version: ArchiveVersion
    let selected: Bool
    var onSelect: () -> Void
    var onPlay: () -> Void = {}
    var onReveal: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? LibraryTokens.accent : LibraryTokens.text3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if let q = version.quality {
                        Text(q).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(LibraryTokens.accentSoft, in: Capsule())
                            .foregroundStyle(LibraryTokens.accent)
                    }
                    if let g = version.releaseGroup {
                        Text(g).font(.system(size: 12)).foregroundStyle(LibraryTokens.text)
                    }
                    if version.isMissing {
                        Label("文件已移动/删除", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(LibraryTokens.fail)
                    }
                }
                if !version.languages.isEmpty {
                    Label(version.languages.joined(separator: " / "), systemImage: "captions.bubble")
                        .font(.system(size: 11)).foregroundStyle(LibraryTokens.text3)
                }
            }
            Spacer()
            Text(version.sizeText).font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(LibraryTokens.text2)

            // Reveal in Finder + play this version.
            Button(action: onReveal) { Image(systemName: "folder") }
                .buttonStyle(.plain).foregroundStyle(LibraryTokens.text3)
                .help("在 Finder 中显示")
            if !version.isMissing {
                Button(action: onPlay) { Image(systemName: "play.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(LibraryTokens.accent)
                    .help("播放此版本")
            }
        }
        .padding(12)
        .background(LibraryTokens.bg2, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(selected ? LibraryTokens.accent : .clear, lineWidth: 1.5))
        .opacity(version.isMissing ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !version.isMissing { onSelect() } }
    }
}

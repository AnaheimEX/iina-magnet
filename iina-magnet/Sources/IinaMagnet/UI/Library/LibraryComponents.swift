//
//  LibraryComponents.swift
//  IinaMagnet
//
//  Shared SwiftUI pieces for the library browser, ported from the handoff
//  design's Poster.jsx / Overview.jsx: rating badges, the tri-state chip, match
//  badges, the poster artwork (with load / fail / unmatched placeholders), the
//  poster card, and the list row.

import SwiftUI

// MARK: - Flow layout (wrapping tag chips)

/// Minimal left-to-right wrapping layout for tag chips (macOS 14 `Layout`).
struct LibraryFlowLayout: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Void) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

// MARK: - Deterministic gradient placeholder (data.jsx posterGrad)

enum PosterGradient {
    /// Title-seeded hue, mirroring the design's hash → gradient placeholder so a
    /// poster-less item still gets a stable, distinct cover.
    static func gradient(seed: String) -> LinearGradient {
        var h: Int32 = 0
        for scalar in seed.unicodeScalars { h = (h &* 31) &+ Int32(bitPattern: scalar.value) }
        let hue = Double(abs(Int(h)) % 360) / 360.0
        let hue2 = (hue + 38.0 / 360.0).truncatingRemainder(dividingBy: 1)
        return LinearGradient(
            colors: [Color(hue: hue, saturation: 0.45, brightness: 0.58),
                     Color(hue: hue2, saturation: 0.42, brightness: 0.36)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Rating badges (BGM / TMDB / 豆瓣)

struct RatingBadgesView: View {
    let ratings: [RatingBadge]
    var onGlass = false

    var body: some View {
        if ratings.isEmpty {
            Text("暂无评分")
                .font(.system(size: 11))
                .foregroundStyle(LibraryTokens.text3)
        } else {
            HStack(spacing: 6) {
                ForEach(ratings, id: \.source) { r in
                    HStack(spacing: 4) {
                        Text(r.source.label)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(LibraryTokens.ratingSource(r.source),
                                        in: RoundedRectangle(cornerRadius: 3))
                        Text(String(format: "%.1f", r.value))
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(onGlass ? .white : LibraryTokens.text)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(onGlass ? AnyShapeStyle(.ultraThinMaterial)
                                        : AnyShapeStyle(LibraryTokens.fill),
                                in: RoundedRectangle(cornerRadius: LibraryTokens.Radius.pill))
                }
            }
        }
    }
}

// MARK: - Tri-state chip

struct StateChip: View {
    let state: ProgressState
    var body: some View {
        switch state {
        case .completed:
            label(state.displayLabel, system: "checkmark", tint: LibraryTokens.done)
        case .inProgress:
            label(state.displayLabel, system: "circle.fill", tint: LibraryTokens.accent)
        case .unseen:
            label(state.displayLabel, system: nil, tint: LibraryTokens.text3)
        }
    }

    private func label(_ text: String, system: String?, tint: Color) -> some View {
        HStack(spacing: 4) {
            if let system { Image(systemName: system).font(.system(size: state == .inProgress ? 7 : 10)) }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - Match status

struct MatchStatusLabel: View {
    let state: MatchState
    var body: some View {
        switch state {
        case .confirmed:
            row(state.displayLabel, system: "checkmark", tint: LibraryTokens.done)
        case .pendingConfirmation:
            row(state.displayLabel, system: "exclamationmark.triangle.fill", tint: LibraryTokens.warn)
        case .unmatched:
            row(state.displayLabel, system: "questionmark", tint: LibraryTokens.unmatched)
        }
    }
    private func row(_ text: String, system: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: system).font(.system(size: 10))
            Text(text).font(.system(size: 11))
        }.foregroundStyle(tint)
    }
}

extension MediaKind {
    /// Shared SF Symbol for this kind (poster badge, sidebar, …). Display *text*
    /// lives on `displayLabel` in the model layer.
    var glyph: String {
        switch self {
        case .tv: return "tv"
        case .movie: return "film"
        case .unknown: return "questionmark.folder"
        }
    }
}

// MARK: - Poster artwork + placeholders

struct PosterArt: View {
    let item: LibraryItemViewModel

    var body: some View {
        ZStack {
            PosterGradient.gradient(seed: item.titleOriginal ?? item.titleZh)
            if item.kind == .unknown || item.posterURL == nil {
                placeholder
            } else if let url = item.posterURL {
                // Cache-first; the title-seeded gradient already sits behind in the
                // ZStack, so a still-loading / failed fetch degrades to that.
                CachedAsyncImage(url: url) { Color.clear }
            }
        }
        .clipped()
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            if item.kind == .unknown {
                Image(systemName: "doc.questionmark").font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.85))
                Text(item.rawName ?? item.titleZh)
                    .font(.system(size: 10)).lineLimit(3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 8)
            } else {
                Text(item.titleZh).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(2)
                    .multilineTextAlignment(.center).padding(.horizontal, 10)
                if let original = item.titleOriginal {
                    Text(original).font(.system(size: 10)).foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Poster card

struct PosterCard: View {
    let item: LibraryItemViewModel
    var onOpen: () -> Void = {}
    var onRemove: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                PosterArt(item: item)
                    .aspectRatio(2.0/3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: LibraryTokens.Radius.poster))
                    .overlay(RoundedRectangle(cornerRadius: LibraryTokens.Radius.poster)
                        .strokeBorder(LibraryTokens.sep, lineWidth: 0.5))

                // type badge (top-left)
                kindBadge.padding(7)

                // match / done badge (top-right)
                VStack { matchBadge }
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(7)

                // resume progress (bottom)
                if let resume = item.resume {
                    VStack {
                        Spacer()
                        ProgressView(value: resume.progress)
                            .tint(LibraryTokens.accent)
                            .scaleEffect(x: 1, y: 0.6, anchor: .bottom)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: LibraryTokens.Radius.poster))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.titleZh).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LibraryTokens.text).lineLimit(1)
                Text(item.caption).font(.system(size: 11))
                    .foregroundStyle(LibraryTokens.text2).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button(role: .destructive, action: onRemove) {
                Label("从媒体库移除", systemImage: "trash")
            }
        }
    }

    private var kindBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: item.kind.glyph).font(.system(size: 9))
            Text(item.kind.displayLabel).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder private var matchBadge: some View {
        switch item.matchState {
        case .pendingConfirmation:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(.white)
                .padding(5).background(LibraryTokens.warn, in: Circle())
        case .unmatched:
            Text("未匹配").font(.system(size: 10))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.ultraThinMaterial, in: Capsule())
        case .confirmed:
            if item.aggregateState == .completed {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white).padding(5)
                    .background(LibraryTokens.done, in: Circle())
            }
        }
    }
}

// MARK: - List row

struct LibraryListRow: View {
    let item: LibraryItemViewModel
    var onOpen: () -> Void = {}
    var onRemove: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            PosterArt(item: item)
                .frame(width: 32, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.titleZh).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LibraryTokens.text).lineLimit(1)
                Text(item.titleOriginal ?? item.rawName ?? "—")
                    .font(.system(size: 11)).foregroundStyle(LibraryTokens.text2).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.kind.displayLabel).font(.system(size: 12)).foregroundStyle(LibraryTokens.text2)
                .frame(width: 56, alignment: .leading)
            Text(item.year.map(String.init) ?? "—").font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(LibraryTokens.text2).frame(width: 48, alignment: .leading)
            RatingBadgesView(ratings: item.ratings).frame(width: 150, alignment: .leading)
            StateChip(state: item.aggregateState).frame(width: 72, alignment: .leading)
            MatchStatusLabel(state: item.matchState).frame(width: 80, alignment: .leading)
            Text(item.versionCount > 1 ? "\(item.versionCount) 版本" : (item.topQuality ?? "—"))
                .font(.system(size: 12)).foregroundStyle(LibraryTokens.text2)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .leading) {
            if item.matchState != .confirmed {
                Rectangle().fill(LibraryTokens.warn).frame(width: 3)
            }
        }
        .background(LibraryTokens.bg2.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button(role: .destructive, action: onRemove) {
                Label("从媒体库移除", systemImage: "trash")
            }
        }
    }
}

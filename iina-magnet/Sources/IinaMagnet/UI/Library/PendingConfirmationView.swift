//
//  PendingConfirmationView.swift
//  IinaMagnet
//
//  The 待确认队列 (Issue 18): works whose metadata match is uncertain
//  (matchState ≠ confirmed). Each row offers a quick 确认 (for a likely-correct
//  pending match) and 改绑 / 重新匹配 — which opens the work's archive page where
//  the manual-match sheet (LibraryEditor.rebind) lives. Driven by an injected
//  list of non-confirmed LibraryItemViewModels + action closures.

import SwiftUI
import SwiftData

public struct PendingConfirmationView: View {
    private let items: [LibraryItemViewModel]
    private let onBack: () -> Void
    private let onOpen: (PersistentIdentifier) -> Void
    private let onConfirm: (PersistentIdentifier) -> Void

    public init(items: [LibraryItemViewModel],
                onBack: @escaping () -> Void = {},
                onOpen: @escaping (PersistentIdentifier) -> Void = { _ in },
                onConfirm: @escaping (PersistentIdentifier) -> Void = { _ in }) {
        self.items = items
        self.onBack = onBack
        self.onOpen = onOpen
        self.onConfirm = onConfirm
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(LibraryTokens.sep)
            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { row($0) }
                    }
                    .padding(LibraryTokens.Spacing.pagePadding)
                }
            }
        }
        .background(LibraryTokens.bg)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 3) { Image(systemName: "chevron.left"); Text("媒体库") }
                    .font(.system(size: 12))
            }.buttonStyle(.plain).foregroundStyle(LibraryTokens.text2)
            Text("待确认队列").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LibraryTokens.text)
            Text("\(items.count)").font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(LibraryTokens.text3)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: LibraryTokens.Spacing.toolbarHeight)
        .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal").font(.system(size: 40))
                .foregroundStyle(LibraryTokens.done)
            Text("没有待确认的作品").font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LibraryTokens.text)
            Text("所有作品都已确认匹配。新扫描到的不确定项会出现在这里。")
                .font(.system(size: 13)).foregroundStyle(LibraryTokens.text2)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }

    private func row(_ item: LibraryItemViewModel) -> some View {
        HStack(spacing: 12) {
            PosterArt(item: item)
                .frame(width: 44, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.titleZh).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LibraryTokens.text).lineLimit(1)
                Text(item.rawName ?? item.titleOriginal ?? item.caption)
                    .font(.system(size: 11)).foregroundStyle(LibraryTokens.text2).lineLimit(1)
                MatchStatusLabel(state: item.matchState)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.matchState == .pendingConfirmation {
                Button("确认") { onConfirm(item.id) }
                    .buttonStyle(.bordered).controlSize(.small).tint(LibraryTokens.done)
            }
            Button(item.matchState == .unmatched ? "搜索匹配" : "改绑") { onOpen(item.id) }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(LibraryTokens.accent)
        }
        .padding(10)
        .background(LibraryTokens.bg2, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            Rectangle().fill(item.matchState == .unmatched ? LibraryTokens.unmatched : LibraryTokens.warn)
                .frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen(item.id) }
    }
}

//
//  ManualMatchSheet.swift
//  IinaMagnet
//
//  The fallback / manual-adaptation UI behind the archive page's 重新匹配 /
//  手动搜索匹配 actions. Two tabs:
//    • 搜索匹配: type a keyword, pick a metadata candidate to re-bind (drives
//      LibraryEditor.applyRematch via the injected closures).
//    • 手动编辑: hand-edit core fields directly (LibraryEditor.applyManual).
//
//  The view is dumb: the host supplies an async `search` closure (provider call)
//  and `onPick` / `onManualSave` callbacks wired to LibraryEditor + a provider.

import SwiftUI

public struct ManualMatchSheet: View {
    private enum Tab: Hashable { case search, edit }

    private let initialQuery: String
    private let initialEdits: ManualEdits
    private let search: (String) async -> [MetadataCandidate]
    private let onPick: (MetadataCandidate) -> Void
    private let onManualSave: (ManualEdits) -> Void
    private let onClose: () -> Void

    public init(initialQuery: String,
                initialEdits: ManualEdits,
                search: @escaping (String) async -> [MetadataCandidate],
                onPick: @escaping (MetadataCandidate) -> Void,
                onManualSave: @escaping (ManualEdits) -> Void,
                onClose: @escaping () -> Void) {
        self.initialQuery = initialQuery
        self.initialEdits = initialEdits
        self.search = search
        self.onPick = onPick
        self.onManualSave = onManualSave
        self.onClose = onClose
    }

    @State private var tab: Tab = .search
    @State private var query = ""
    @State private var results: [MetadataCandidate] = []
    @State private var searching = false
    @State private var hasSearched = false

    // Manual-edit fields.
    @State private var titleZh = ""
    @State private var titleJa = ""
    @State private var year = ""
    @State private var kind: MediaKind = .tv

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                Text("搜索匹配").tag(Tab.search)
                Text("手动编辑").tag(Tab.edit)
            }
            .pickerStyle(.segmented).labelsHidden().padding(12)

            Group {
                switch tab {
                case .search: searchTab
                case .edit:   editTab
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 460, height: 520)
        .background(LibraryTokens.bg)
        .onAppear {
            query = initialQuery
            titleZh = initialEdits.titleZh ?? ""
            titleJa = initialEdits.titleJa ?? ""
            year = initialEdits.releaseYear.map(String.init) ?? ""
            kind = initialEdits.kind ?? .tv
        }
    }

    private var header: some View {
        HStack {
            Text("匹配元数据").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LibraryTokens.text)
            Spacer()
            Button { onClose() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(LibraryTokens.text3)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    // MARK: Search

    private var searchTab: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(LibraryTokens.text3)
                TextField("按标题搜索（bangumi.tv）", text: $query)
                    .textFieldStyle(.plain).onSubmit { runSearch() }
                Button("搜索", action: runSearch)
                    .buttonStyle(.borderedProminent).tint(LibraryTokens.accent)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)

            if searching {
                ProgressView().frame(maxHeight: .infinity)
            } else if results.isEmpty && hasSearched {
                Text("没有找到候选项，换个关键词试试。")
                    .font(.system(size: 12)).foregroundStyle(LibraryTokens.text3)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(results, id: \.externalId) { c in
                            candidateRow(c)
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
        }
    }

    private func candidateRow(_ c: MetadataCandidate) -> some View {
        Button { onPick(c) } label: {
            HStack(spacing: 10) {
                ZStack {
                    PosterGradient.gradient(seed: c.title)
                    if let url = c.posterURL {
                        AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fill) }
                            placeholder: { Color.clear }
                    }
                }
                .frame(width: 34, height: 48).clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LibraryTokens.text).lineLimit(1)
                    Text([c.year.map(String.init), "bgm:\(c.externalId)"].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(LibraryTokens.text3)
                }
                Spacer()
                Image(systemName: "arrow.right.circle").foregroundStyle(LibraryTokens.accent)
            }
            .padding(8)
            .background(LibraryTokens.fill, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true; hasSearched = true
        Task {
            let found = await search(q)
            await MainActor.run {
                results = found
                searching = false
            }
        }
    }

    // MARK: Manual edit

    private var editTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("中文标题", text: $titleZh)
            field("原名（日 / 英）", text: $titleJa)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("年份").font(.system(size: 11)).foregroundStyle(LibraryTokens.text3)
                    TextField("2023", text: $year).textFieldStyle(.roundedBorder).frame(width: 100)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("类型").font(.system(size: 11)).foregroundStyle(LibraryTokens.text3)
                    Picker("", selection: $kind) {
                        Text(MediaKind.tv.displayLabel).tag(MediaKind.tv)
                        Text(MediaKind.movie.displayLabel).tag(MediaKind.movie)
                        Text(MediaKind.unknown.displayLabel).tag(MediaKind.unknown)
                    }.labelsHidden().frame(width: 120)
                }
            }
            Spacer()
            Button("保存修改") {
                onManualSave(ManualEdits(
                    titleZh: titleZh,
                    titleJa: titleJa,
                    releaseYear: Int(year.trimmingCharacters(in: .whitespaces)),
                    kind: kind))
            }
            .buttonStyle(.borderedProminent).tint(LibraryTokens.accent)
            .frame(maxWidth: .infinity)
        }
        .padding(16)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(LibraryTokens.text3)
            TextField(label, text: text).textFieldStyle(.roundedBorder)
        }
    }
}

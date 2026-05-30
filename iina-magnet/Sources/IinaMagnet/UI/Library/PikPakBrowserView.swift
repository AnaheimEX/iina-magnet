//
//  PikPakBrowserView.swift
//  IinaMagnet
//
//  Browses the signed-in PikPak drive: folders drill in (breadcrumb to go
//  back), and tapping a video resolves a fresh direct URL and hands it to iina
//  via IinaBridge — playing the cloud file directly, no download step.

import SwiftUI
import OSLog

/// Pure browsing order: folders first, then case/number-aware name sort.
enum PikPakBrowsing {
    static func ordered(_ files: [PikPakFile]) -> [PikPakFile] {
        files.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

struct PikPakBrowserView: View {
    private static let logger = Logger(subsystem: "iina-magnet", category: "pikpak-browser")

    private struct Folder: Hashable { let id: String; let name: String }
    private enum Phase: Equatable { case loading, loaded, failed(String) }

    @State private var stack: [Folder] = [Folder(id: "", name: "全部文件")]
    @State private var entries: [PikPakFile] = []
    @State private var phase: Phase = .loading
    @State private var openingID: String?
    @State private var openError: String?

    private var currentID: String { stack.last?.id ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider().overlay(LibraryTokens.sep)
            content
        }
        .task(id: currentID) { await load() }
    }

    // MARK: Breadcrumb

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(stack.enumerated()), id: \.element) { index, folder in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.system(size: 9))
                            .foregroundStyle(LibraryTokens.text3)
                    }
                    Button(folder.name) { stack = Array(stack.prefix(index + 1)) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: index == stack.count - 1 ? .semibold : .regular))
                        .foregroundStyle(index == stack.count - 1 ? LibraryTokens.text : LibraryTokens.text2)
                        .disabled(index == stack.count - 1)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(LibraryTokens.bg2)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            centered { ProgressView().controlSize(.small) }
        case .failed(let message):
            centered {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 30))
                        .foregroundStyle(LibraryTokens.warn)
                    Text(message).font(.system(size: 13)).foregroundStyle(LibraryTokens.text2)
                        .multilineTextAlignment(.center).frame(maxWidth: 360)
                    Button("重试") { Task { await load() } }.controlSize(.small)
                }
            }
        case .loaded where entries.isEmpty:
            centered {
                VStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 30)).foregroundStyle(LibraryTokens.text3)
                    Text("这个文件夹是空的").font(.system(size: 13)).foregroundStyle(LibraryTokens.text2)
                }
            }
        case .loaded:
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if let openError {
                    Text(openError).font(.system(size: 11)).foregroundStyle(LibraryTokens.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                }
                ForEach(PikPakBrowsing.ordered(entries)) { file in
                    row(file)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func row(_ file: PikPakFile) -> some View {
        let playable = !file.isFolder && file.isVideo
        return Button {
            if file.isFolder { stack.append(Folder(id: file.id, name: file.name)) }
            else if playable { Task { await open(file) } }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon(for: file)).font(.system(size: 14))
                    .frame(width: 20)
                    .foregroundStyle(file.isFolder ? LibraryTokens.accent
                                     : (playable ? LibraryTokens.text : LibraryTokens.text3))
                Text(file.name).font(.system(size: 13)).lineLimit(1)
                    .foregroundStyle(file.isFolder || playable ? LibraryTokens.text : LibraryTokens.text3)
                Spacer(minLength: 8)
                if openingID == file.id {
                    ProgressView().controlSize(.small)
                } else if !file.isFolder, file.size > 0 {
                    Text(LibraryFormatting.size(file.size)).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(LibraryTokens.text3)
                } else if file.isFolder {
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(LibraryTokens.text3)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!file.isFolder && !playable)
    }

    private func icon(for file: PikPakFile) -> String {
        if file.isFolder { return "folder.fill" }
        if file.isVideo { return "play.rectangle.fill" }
        return "doc"
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        inner().frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }

    // MARK: Actions

    @MainActor
    private func load() async {
        phase = .loading
        openError = nil
        do {
            let files = try await PikPakDrive.shared.list(parentID: currentID)
            entries = files
            phase = .loaded
        } catch {
            phase = .failed(message(for: error))
            Self.logger.error("list failed: \(self.message(for: error), privacy: .public)")
        }
    }

    @MainActor
    private func open(_ file: PikPakFile) async {
        openingID = file.id
        openError = nil
        defer { openingID = nil }
        do {
            let url = try await PikPakDrive.shared.playbackURL(fileID: file.id)
            guard let bridge = IinaBridgeRegistry.bridge else {
                openError = "无法连接到 IINA 播放器"
                return
            }
            bridge.openForPlayback(url)
        } catch {
            openError = "无法播放「\(file.name)」：\(message(for: error))"
        }
    }

    private func message(for error: Error) -> String {
        (error as? PikPakError)?.errorDescription ?? error.localizedDescription
    }
}

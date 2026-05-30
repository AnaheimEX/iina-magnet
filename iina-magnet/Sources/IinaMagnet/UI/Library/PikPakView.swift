//
//  PikPakView.swift
//  IinaMagnet
//
//  PikPak cloud-drive screen, reached from the library sidebar (下方「最近添加」).
//  Phase 3 entry point: this is the home for PikPak login + file browsing. The
//  auth + file-listing + play-direct-link wiring lands in the next unit; for now
//  it presents the connect prompt so the access point exists.

import SwiftUI

public struct PikPakView: View {
    private let onBack: () -> Void

    public init(onBack: @escaping () -> Void = {}) {
        self.onBack = onBack
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(LibraryTokens.sep)
            connectPrompt
        }
        .background(LibraryTokens.bg)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 3) { Image(systemName: "chevron.left"); Text("媒体库") }
                    .font(.system(size: 12))
            }.buttonStyle(.plain).foregroundStyle(LibraryTokens.text2)
            HStack(spacing: 6) {
                Image(systemName: "cloud.fill").foregroundStyle(LibraryTokens.accent)
                Text("PikPak 网盘").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LibraryTokens.text)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: LibraryTokens.Spacing.toolbarHeight)
        .background(.ultraThinMaterial)
    }

    private var connectPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "cloud").font(.system(size: 44)).foregroundStyle(LibraryTokens.accent)
            Text("连接你的 PikPak 网盘").font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LibraryTokens.text)
            Text("登录后即可浏览网盘里的视频，并直接在 IINA 中播放。")
                .font(.system(size: 13)).foregroundStyle(LibraryTokens.text2)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Button { /* login flow — next unit */ } label: {
                Text("登录 PikPak").padding(.horizontal, 18).padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent).tint(LibraryTokens.accent).padding(.top, 6)
            Text("接入开发中").font(.system(size: 11)).foregroundStyle(LibraryTokens.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
}

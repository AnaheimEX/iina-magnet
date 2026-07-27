//
//  PikPakView.swift
//  IinaMagnet
//
//  PikPak cloud-drive screen, reached from the library sidebar (下方「最近添加」).
//  Login goes through the official mypikpak.com page in a web view; on success
//  we adopt the captured session (PikPakAuth.shared). File browsing + direct
//  play wiring lands in the next unit — for now the signed-in state shows a
//  placeholder.

import Foundation
import SwiftUI

public struct PikPakView: View {
    private let onBack: () -> Void

    @State private var signedIn = false
    @State private var userID: String?
    @State private var showLogin = false
    @State private var showTasks = false        // 文件浏览 vs 离线任务

    public init(onBack: @escaping () -> Void = {}) {
        self.onBack = onBack
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(LibraryTokens.sep)
            if signedIn {
                if showTasks { PikPakTaskCenterView() } else { PikPakBrowserView() }
            } else {
                connectPrompt
            }
        }
        .background(LibraryTokens.bg)
        .task { await refreshState() }
        .onReceive(NotificationCenter.default.publisher(
            for: PikPakAuth.sessionDidChangeNotification
        )) { _ in
            Task { await refreshState() }
        }
        .sheet(isPresented: $showLogin) {
            PikPakLoginSheet(
                onCancel: { showLogin = false },
                onCapture: { cred in
                    Task {
                        await PikPakAuth.shared.adopt(cred)
                        await refreshState()
                        if signedIn { showLogin = false }
                    }
                })
        }
    }

    private func refreshState() async {
        signedIn = await PikPakAuth.shared.isSignedIn
        userID = await PikPakAuth.shared.userID
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
            if signedIn {
                Button { showTasks.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showTasks ? "folder" : "arrow.down.circle")
                        Text(showTasks ? "文件" : "离线任务")
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(showTasks ? LibraryTokens.text2 : LibraryTokens.accent)
                .help(showTasks ? "返回文件浏览" : "查看离线下载任务")
                Button("退出登录") {
                    Task { await PikPakAuth.shared.signOut(); await refreshState() }
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(LibraryTokens.text2)
            }
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
            Button { showLogin = true } label: {
                Text("登录 PikPak").padding(.horizontal, 18).padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent).tint(LibraryTokens.accent).padding(.top, 6)
            Text("将打开 PikPak 官方登录页，登录后自动连接").font(.system(size: 11))
                .foregroundStyle(LibraryTokens.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
}

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
    @State private var isRestoring = false
    @State private var restoreFailed = false

    public init(onBack: @escaping () -> Void = {}) {
        self.onBack = onBack
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(CloudTokens.sep)
            if signedIn {
                if showTasks { PikPakTaskCenterView() } else { PikPakBrowserView() }
            } else if isRestoring {
                restoreProgress
            } else {
                connectPrompt
            }
        }
        .background(CloudTokens.bg)
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
        let wasSignedIn = signedIn
        let isSignedInNow = await PikPakAuth.shared.isSignedIn
        signedIn = isSignedInNow
        userID = await PikPakAuth.shared.userID

        // Silent login restore on first appearance: when there is no Keychain
        // session (the previous quit cleared it, or the refresh token has
        // rotated past what Keychain held), the persistent web cookies may
        // still hold a valid login. Boot the SPA offscreen, read its tokens
        // back, adopt them, and verify — all without prompting. Only when the
        // web session is also gone do we leave the connect prompt visible.
        if !isSignedInNow, !wasSignedIn, !restoreFailed, !showLogin {
            await attemptSilentRestore()
        }
    }

    /// One silent restore attempt per view lifetime. Repeated attempts would
    /// each spin up an offscreen web view on every sidebar re-entry; the auth
    /// actor coalesces them onto one launch-wide attempt anyway.
    private func attemptSilentRestore() async {
        isRestoring = true
        defer { isRestoring = false }

        guard await PikPakAuth.shared.restoreFromWebSessionIfNeeded() else {
            restoreFailed = true            // nothing to restore; show the prompt
            return
        }
        // A restored session is unverified — PikPak may have revoked it server
        // side while the app was closed. Confirm with a cheap authenticated
        // call before trusting it, and only tear down on a confirmed rejection:
        // a transient network failure must keep both the adopted session and
        // the persistent web cookies, so the drive retry pipeline (and the
        // next launch) can still recover instead of forcing a fresh login.
        switch await PikPakDrive.shared.verifySession() {
        case .unavailable:
            signedIn = true
            userID = await PikPakAuth.shared.userID
        case .dead:
            await PikPakAuth.shared.signOut()
            restoreFailed = true
        case .valid:
            signedIn = true
            userID = await PikPakAuth.shared.userID
        }
    }

    private var restoreProgress: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("正在恢复 PikPak 登录…")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CloudTokens.text)
            Text("首次打开会从浏览器会话自动恢复登录状态")
                .font(.system(size: 12))
                .foregroundStyle(CloudTokens.text2)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 3) { Image(systemName: "xmark"); Text("关闭") }
                    .font(.system(size: 12))
            }.buttonStyle(.plain).foregroundStyle(CloudTokens.text2)
            HStack(spacing: 6) {
                Image(systemName: "cloud.fill").foregroundStyle(CloudTokens.accent)
                Text("PikPak 网盘").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CloudTokens.text)
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
                .foregroundStyle(showTasks ? CloudTokens.text2 : CloudTokens.accent)
                .help(showTasks ? "返回文件浏览" : "查看离线下载任务")
                Button("退出登录") {
                    Task { await PikPakAuth.shared.signOut(); await refreshState() }
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(CloudTokens.text2)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: CloudTokens.Spacing.toolbarHeight)
        .background(.ultraThinMaterial)
    }

    private var connectPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "cloud").font(.system(size: 44)).foregroundStyle(CloudTokens.accent)
            Text("连接你的 PikPak 网盘").font(.system(size: 17, weight: .semibold))
                .foregroundStyle(CloudTokens.text)
            Text("登录后即可浏览网盘里的视频，并直接在 IINA 中播放。")
                .font(.system(size: 13)).foregroundStyle(CloudTokens.text2)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Button { showLogin = true } label: {
                Text("登录 PikPak").padding(.horizontal, 18).padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent).tint(CloudTokens.accent).padding(.top, 6)
            Text("将打开 PikPak 官方登录页，登录后自动连接").font(.system(size: 11))
                .foregroundStyle(CloudTokens.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
}

//
//  MikanView.swift
//  IinaMagnet
//
//  Mikan (mikanani.me) browser, reached from the library sidebar below PikPak.
//  Clicking a magnet / .torrent link on the page is intercepted and offered to
//  PikPak: save it as an offline-download task, or save-and-cloud-play (wait
//  for the cloud file to become playable, then open it in iina). Closes the
//  loop: discover on Mikan → store in PikPak → play from the cloud.

import SwiftUI
import WebKit
import OSLog

public struct MikanView: View {
    private static let logger = Logger(subsystem: "iina-magnet", category: "mikan")

    private let onBack: () -> Void

    @State private var pending: Torrent?
    @State private var busy = false
    @State private var toast: String?

    public init(onBack: @escaping () -> Void = {}) { self.onBack = onBack }

    struct Torrent: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let url: String          // magnet:… or https://…/x.torrent
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(LibraryTokens.sep)
            MikanWebView { name, url in
                pending = Torrent(name: name, url: url)
            }
        }
        .background(LibraryTokens.bg)
        .overlay(alignment: .bottom) { if let toast { toastBar(toast) } }
        .sheet(item: $pending) { torrent in actionSheet(torrent) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 3) { Image(systemName: "chevron.left"); Text("媒体库") }
                    .font(.system(size: 12))
            }.buttonStyle(.plain).foregroundStyle(LibraryTokens.text2)
            HStack(spacing: 6) {
                Image(systemName: "leaf.fill").foregroundStyle(LibraryTokens.accent)
                Text("蜜柑计划").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LibraryTokens.text)
            }
            Spacer()
            Text("点击磁力 / 种子可保存到 PikPak").font(.system(size: 11))
                .foregroundStyle(LibraryTokens.text3)
        }
        .padding(.horizontal, 14)
        .frame(height: LibraryTokens.Spacing.toolbarHeight)
        .background(.ultraThinMaterial)
    }

    // MARK: Action sheet

    private func actionSheet(_ torrent: Torrent) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 36))
                .foregroundStyle(LibraryTokens.accent)
            Text("保存到 PikPak").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LibraryTokens.text)
            Text(torrent.name.isEmpty ? "种子任务（由 PikPak 自动命名）" : torrent.name)
                .font(.system(size: 12)).foregroundStyle(LibraryTokens.text2)
                .lineLimit(3).multilineTextAlignment(.center).frame(maxWidth: 360)

            if busy {
                ProgressView().controlSize(.small)
                Text("正在处理…").font(.system(size: 11)).foregroundStyle(LibraryTokens.text3)
            } else {
                HStack(spacing: 10) {
                    Button("仅保存到网盘") { run(torrent, play: false) }
                        .buttonStyle(.bordered)
                    Button("保存并云播") { run(torrent, play: true) }
                        .buttonStyle(.borderedProminent).tint(LibraryTokens.accent)
                }
                Button("取消") { pending = nil }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(LibraryTokens.text3)
            }
        }
        .padding(28).frame(width: 420)
    }

    private func toastBar(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(LibraryTokens.text)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Actions

    private func run(_ torrent: Torrent, play: Bool) {
        Task {
            guard await PikPakAuth.shared.isSignedIn else {
                pending = nil
                showToast("请先在「PikPak 网盘」登录后再保存")
                return
            }
            busy = true
            defer { busy = false; pending = nil }
            do {
                let task = try await PikPakDrive.shared.offlineDownload(url: torrent.url, name: torrent.name)
                Self.logger.info("offline task added: \(task.id, privacy: .public)")
                if play, !task.fileID.isEmpty {
                    showToast("已添加，正在等待可播放…")
                    let url = try await PikPakDrive.shared.waitForPlayableURL(fileID: task.fileID)
                    IinaBridgeRegistry.bridge?.openForPlayback(url, options: PlaybackOptions(
                        userAgent: PikPakConfig.web.userAgent, enlargeNetworkCache: true))
                    showToast("已在 IINA 中开始播放")
                } else {
                    showToast("已添加到 PikPak 离线下载，完成后可在网盘播放")
                }
            } catch {
                showToast((error as? PikPakError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            withAnimation { if toast == text { toast = nil } }
        }
    }
}

// MARK: - Web view

private struct MikanWebView: NSViewRepresentable {
    var onCapture: (_ name: String, _ url: String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://mikanani.me/")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onCapture: (_ name: String, _ url: String) -> Void
        init(onCapture: @escaping (_ name: String, _ url: String) -> Void) { self.onCapture = onCapture }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
            if url.scheme == "magnet" {
                decisionHandler(.cancel)
                // Use the magnet's display name (real title) when present; else
                // leave empty so PikPak names it from the torrent metadata.
                onCapture(Self.magnetName(url) ?? "", url.absoluteString)
            } else if url.pathExtension.lowercased() == "torrent" {
                decisionHandler(.cancel)
                // A .torrent URL's filename is just the info-hash — not a usable
                // title — so pass no name and let PikPak resolve the real one.
                onCapture("", url.absoluteString)
            } else {
                decisionHandler(.allow)
            }
        }

        /// The `dn` (display name) parameter of a magnet URI, if present.
        static func magnetName(_ url: URL) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "dn" }?.value?.removingPercentEncoding
        }
    }
}

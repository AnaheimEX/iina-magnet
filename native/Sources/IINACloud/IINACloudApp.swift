import AppKit
import CFNetwork
import IinaMagnet

@main
@MainActor
enum IINACloudApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = CloudApplicationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class CloudApplicationDelegate: NSObject, NSApplicationDelegate {
    private let bridge = PluginPlaybackBridge()
    private var bootstrapped = false
    private var persistenceObserver: NSObjectProtocol?
    private var didShowPersistenceWarning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 IINA Cloud", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"),
                                       ("复制", "copy:", "c"), ("粘贴", "paste:", "v"),
                                       ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        IinaBridgeRegistry.bridge = bridge
        persistenceObserver = NotificationCenter.default.addObserver(
            forName: KeychainPikPakTokenStore.persistenceFailureNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.didShowPersistenceWarning else { return }
                self.didShowPersistenceWarning = true
                self.showError("登录状态暂未保存到钥匙串。当前登录仍可使用；请允许本应用访问钥匙串，再重新登录。不会将令牌明文写入偏好文件。")
            }
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        do {
            guard filenames.count == 1 else { throw PluginPlaybackBridge.error("请从 IINA 插件菜单打开网页窗口。") }
            let launchURL = URL(fileURLWithPath: filenames[0]).standardizedFileURL
            guard launchURL == bridge.directory.appendingPathComponent("launch.iina-cloud-request"),
                  launchURL.resolvingSymlinksInPath() == launchURL else {
                throw PluginPlaybackBridge.error("无效的插件启动请求。")
            }
            let launch = try JSONDecoder().decode(LaunchRequest.self, from: Data(contentsOf: launchURL))
            guard abs(Date().timeIntervalSince1970 * 1000 - launch.createdAt) < 60_000,
                  !launch.token.isEmpty, launch.token.count < 128,
                  ["mikan", "pikpak"].contains(launch.page) else {
                throw PluginPlaybackBridge.error("启动请求已过期，请重新点击 IINA 插件菜单。")
            }
            bridge.configure(token: launch.token)
            if !bootstrapped {
                IinaBridgeRegistry.bridge = bridge
                IinaMagnetBootstrap.start()
                bootstrapped = true
            }
            if launch.page == "mikan" { IinaMagnetBootstrap.openMikan() }
            else { IinaMagnetBootstrap.openPikPak() }
            sender.reply(toOpenOrPrint: .success)
        } catch {
            sender.reply(toOpenOrPrint: .failure)
            showError(error.localizedDescription)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        bridge.shutdown()
        IinaMagnetBootstrap.shutdown()
        if let persistenceObserver { NotificationCenter.default.removeObserver(persistenceObserver) }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "IINA Cloud"
        alert.informativeText = message
        alert.runModal()
    }
}

private struct LaunchRequest: Decodable {
    let page: String
    let token: String
    let createdAt: Double
}

/// A private file mailbox uses only IINA's public file and plugin APIs.
/// No account tokens, web cookies, local HTTP server, or signed URLs in argv.
@MainActor
private final class PluginPlaybackBridge: IinaBridge {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.colliderli.iina/plugins/.data/io.iina.magnet.cloud", isDirectory: true)
    private var token = ""
    private var activeID: String?

    static func error(_ message: String) -> NSError {
        NSError(domain: "IINACloud", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func configure(token: String) {
        if self.token != token { cancelPending() }
        self.token = token
    }

    func openForPlayback(_ url: URL) { openForPlayback(url, options: PlaybackOptions()) }

    func openForPlayback(_ url: URL, options: PlaybackOptions) {
        Task {
            do { try await openForPlaybackAndWait(url, options: options) }
            catch is CancellationError { }
            catch {
                let alert = NSAlert()
                alert.messageText = "无法打开云端视频"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    func openForPlaybackAndWait(_ url: URL, options: PlaybackOptions) async throws {
        try Task.checkCancellation()
        guard url.scheme?.lowercased() == "https", !token.isEmpty else {
            throw Self.error("请从 IINA 插件菜单打开网盘后重试。")
        }
        guard activeID == nil else { throw Self.error("另一个视频仍在加载，请稍后重试。") }
        let id = UUID().uuidString
        let launchToken = token
        activeID = id
        var completed = false
        defer {
            if !completed { try? write(["id": id, "token": launchToken], name: "cancel.json") }
            removeIfOwned("playback.json", id: id)
            removeIfOwned("result.json", id: id)
            if activeID == id { activeID = nil }
        }
        var request: [String: Any] = [
            "id": id, "token": launchToken, "createdAt": Date().timeIntervalSince1970 * 1000,
            "url": url.absoluteString, "cache": options.enlargeNetworkCache,
        ]
        if let userAgent = options.userAgent { request["userAgent"] = userAgent }
        if let proxy = systemHTTPProxy() { request["proxy"] = proxy }
        try write(request, name: "playback.json")
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard activeID == id, token == launchToken else { throw CancellationError() }
            if let result = read("result.json"), result["id"] as? String == id,
               result["token"] as? String == launchToken {
                guard result["ok"] as? Bool == true else {
                    throw Self.error("IINA 加载视频失败，请检查网络或重新获取播放地址。")
                }
                completed = true
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Self.error("IINA 未能在 60 秒内确认视频加载。请确认播放器和插件仍在运行。")
    }

    func cancelPending() {
        if let id = activeID { try? write(["id": id, "token": token], name: "cancel.json") }
        activeID = nil
    }

    func shutdown() {
        cancelPending()
        if !token.isEmpty { try? write(["token": token], name: "closed.json") }
    }

    private func read(_ name: String) -> [String: Any]? {
        let path = directory.appendingPathComponent(name)
        guard path.resolvingSymlinksInPath() == path,
              let data = try? Data(contentsOf: path), data.count < 65536 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func write(_ object: [String: Any], name: String) throws {
        guard directory.resolvingSymlinksInPath() == directory else { throw Self.error("插件通信目录无效。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent(name)
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    private func removeIfOwned(_ name: String, id: String) {
        if read(name)?["id"] as? String == id { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
    }

    private func systemHTTPProxy() -> String? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              (settings[kCFNetworkProxiesHTTPSEnable as String] as? NSNumber)?.boolValue == true,
              let host = settings[kCFNetworkProxiesHTTPSProxy as String] as? String,
              let port = settings[kCFNetworkProxiesHTTPSPort as String] as? Int,
              (1...65535).contains(port) else { return nil }
        var url = URLComponents()
        url.scheme = "http"
        url.host = host
        url.port = port
        return url.url?.absoluteString
    }
}

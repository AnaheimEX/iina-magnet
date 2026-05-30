//
//  PikPakDrive.swift
//  IinaMagnet
//
//  PikPak drive API: list folders/files and resolve a playable direct URL for a
//  video, using the session from PikPakAuth. Mirrors the alist/OpenList driver:
//  GET api-drive.mypikpak.net/drive/v1/files with Bearer auth; on PikPak's error
//  codes it refreshes the access token (16 / 4121 / 4122) or re-signs a captcha
//  token (9) and retries.

import Foundation

// MARK: - Public model

public struct PikPakFile: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let isFolder: Bool
    public let size: Int64
    public let mimeType: String?
    public let thumbnailURL: URL?
    public let modifiedTime: Date?

    public init(id: String, name: String, isFolder: Bool, size: Int64,
                mimeType: String?, thumbnailURL: URL?, modifiedTime: Date?) {
        self.id = id
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.mimeType = mimeType
        self.thumbnailURL = thumbnailURL
        self.modifiedTime = modifiedTime
    }

    /// Whether this file looks like a playable video (by MIME, else extension).
    public var isVideo: Bool {
        if let mimeType, mimeType.hasPrefix("video/") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return Self.videoExtensions.contains(ext)
    }

    static let videoExtensions: Set<String> = [
        "mp4", "mkv", "mov", "avi", "wmv", "flv", "webm", "m4v", "mpg", "mpeg",
        "ts", "m2ts", "rmvb", "rm", "3gp", "vob", "ogv", "f4v",
    ]
}

/// A PikPak offline-download task.
public struct PikPakTask: Sendable, Equatable {
    public let id: String
    public let fileID: String
    public let name: String
    public let phase: String        // PHASE_TYPE_RUNNING / _COMPLETE / _PENDING / _ERROR

    public var isComplete: Bool { phase == "PHASE_TYPE_COMPLETE" }
}

// MARK: - Drive client

public actor PikPakDrive {
    public static let shared = PikPakDrive()

    private let auth: PikPakAuth
    private let http: PikPakHTTPClient
    private let config: PikPakConfig

    /// Cloud folder offline downloads are saved into; created on first use.
    public var offlineFolderName = "Pack From Shared"
    private var cachedOfflineFolderID: String?

    public init(auth: PikPakAuth = .shared,
                http: PikPakHTTPClient = URLSessionPikPakClient(),
                config: PikPakConfig = .web) {
        self.auth = auth
        self.http = http
        self.config = config
    }

    /// Lists a folder's children (parentID "" = root), following pagination.
    public func list(parentID: String = "") async throws -> [PikPakFile] {
        var files: [PikPakFile] = []
        var pageToken: String? = ""           // "" → first page
        repeat {
            let query = [
                "parent_id": parentID,
                "thumbnail_size": "SIZE_LARGE",
                "with_audit": "true",
                "limit": "100",
                "filters": #"{"phase":{"eq":"PHASE_TYPE_COMPLETE"},"trashed":{"eq":false}}"#,
                "page_token": pageToken ?? "",
            ]
            let data = try await authorizedGet(path: "/drive/v1/files", query: query)
            let resp = try decode(PPFilesResponse.self, from: data)
            files.append(contentsOf: (resp.files ?? []).map(\.asPikPakFile))
            let next = resp.next_page_token
            pageToken = (next?.isEmpty == false) ? next : nil
        } while pageToken != nil
        return files
    }

    /// A fresh, directly playable URL for a video file. Re-fetches the file's
    /// detail so the returned link isn't a stale (expired) one.
    public func playbackURL(fileID: String) async throws -> URL {
        let data = try await authorizedGet(path: "/drive/v1/files/\(fileID)", query: [:])
        let file = try decode(PPFile.self, from: data)
        guard let url = file.bestPlaybackURL else {
            throw PikPakError.api(code: -1, message: "该文件没有可播放的链接")
        }
        return url
    }

    /// Adds an offline-download task (magnet / torrent / direct URL) that saves
    /// into a named cloud folder (default "Pack From Shared", created if absent)
    /// so saved titles are grouped and readable. Returns the created task (its
    /// `fileID` is the cloud file, usable for playback once content arrives).
    @discardableResult
    public func offlineDownload(url: String, name: String = "") async throws -> PikPakTask {
        let parent = try await offlineFolderID()
        let request = OfflineDownloadRequest(
            name: name,
            url: .init(url: url),
            parent_id: parent,
            folder_type: "")
        let data = try await authorizedPost(path: "/drive/v1/files", body: request)
        let resp = try decode(OfflineDownloadResponse.self, from: data)
        guard let task = resp.task?.asTask else {
            throw PikPakError.api(code: -3, message: "PikPak 未返回离线任务")
        }
        return task
    }

    /// Id of the offline-download target folder, resolved (find-or-create) once
    /// and cached.
    private func offlineFolderID() async throws -> String {
        if let cached = cachedOfflineFolderID { return cached }
        let id = try await findOrCreateFolder(named: offlineFolderName, parentID: "")
        cachedOfflineFolderID = id
        return id
    }

    private func findOrCreateFolder(named name: String, parentID: String) async throws -> String {
        if let existing = try await list(parentID: parentID).first(where: {
            $0.isFolder && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return existing.id
        }
        let data = try await authorizedPost(path: "/drive/v1/files",
                                             body: CreateFolderRequest(parent_id: parentID, name: name))
        let resp = try decode(CreateFolderResponse.self, from: data)
        guard let id = resp.file?.id, !id.isEmpty else {
            throw PikPakError.api(code: -5, message: "无法创建文件夹「\(name)」")
        }
        return id
    }

    /// Polls a freshly-created file until it has a playable URL (content has
    /// started arriving), so an offline task can be "cloud-played" once ready.
    public func waitForPlayableURL(fileID: String, timeoutSeconds: Double = 40,
                                   pollSeconds: Double = 2) async throws -> URL {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            if let url = try? await playbackURL(fileID: fileID) { return url }
            if Date() >= deadline {
                throw PikPakError.api(code: -4, message: "文件仍在下载中，请稍后在 PikPak 网盘里播放")
            }
            try await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
        }
    }

    // MARK: - Request plumbing

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw PikPakError.decoding(String(data: data, encoding: .utf8) ?? "\(error)") }
    }

    private func authorizedGet(path: String, query: [String: String]) async throws -> Data {
        let url = buildURL(path: path, query: query)
        let action = PikPakCrypto.action(method: "GET", url: url)
        return try await authorized(action: action) { try await self.http.getJSON(url, headers: $0) }
    }

    private func authorizedPost<Body: Encodable>(path: String, body: Body) async throws -> Data {
        let url = buildURL(path: path, query: [:])
        let action = PikPakCrypto.action(method: "POST", url: url)
        let encoded = try JSONEncoder().encode(body)
        return try await authorized(action: action) { try await self.http.postJSON(url, body: encoded, headers: $0) }
    }

    /// Runs an authorized request, applying PikPak's error-code retry policy
    /// (token refresh on 16/4121/4122, captcha re-sign on 9) up to a small
    /// budget. `perform` is the bare HTTP call given the auth headers.
    private func authorized(action: String,
                            _ perform: (_ headers: [String: String]) async throws -> (Data, Int)) async throws -> Data {
        // Seed with the captcha token captured at web login, so the first call
        // already carries a valid one (no salt-dependent re-sign needed).
        var captcha = await auth.currentCaptchaToken
        var triedRefresh = false
        var triedCaptcha = false

        while true {
            let token = try await auth.validAccessToken()
            var headers = ["Authorization": "Bearer \(token)",
                           "User-Agent": await auth.userAgent]
            if let device = await auth.currentDeviceID { headers["X-Device-ID"] = device }
            if !captcha.isEmpty { headers["X-Captcha-Token"] = captcha }

            let (data, status) = try await perform(headers)
            guard let code = errorCode(in: data, status: status) else { return data }

            switch code {
            case 16, 4121, 4122:                             // access token expired
                guard !triedRefresh else { throw apiError(in: data, status: status, code: code) }
                triedRefresh = true
                _ = try await auth.refreshAccessToken()
            case 9:                                          // captcha token expired
                guard !triedCaptcha else { throw apiError(in: data, status: status, code: code) }
                triedCaptcha = true
                // Try a self-signed token; if that's rejected (stale salts), ask
                // the user to re-login so we can re-capture a valid one.
                do { captcha = try await auth.captchaToken(forAction: action, refresh: true) }
                catch { throw PikPakError.captchaRequired("PikPak 验证已过期，请重新登录 PikPak。") }
            default:
                throw apiError(in: data, status: status, code: code)
            }
        }
    }

    private func buildURL(path: String, query: [String: String]) -> URL {
        let base = config.driveBaseURL.appendingPathComponent(path.hasPrefix("/")
            ? String(path.dropFirst()) : path)
        guard !query.isEmpty,
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps.url ?? base
    }

    /// Returns PikPak's error_code if the body is an error envelope (or the HTTP
    /// status if non-2xx with no envelope), else nil for success.
    private func errorCode(in data: Data, status: Int) -> Int? {
        if let envelope = try? JSONDecoder().decode(PikPakErrorResponse.self, from: data),
           let code = envelope.error_code, code != 0 {
            return code
        }
        return status >= 400 ? status : nil
    }

    private func apiError(in data: Data, status: Int, code: Int) -> PikPakError {
        let envelope = try? JSONDecoder().decode(PikPakErrorResponse.self, from: data)
        let message = envelope?.error_description?.nonEmpty ?? envelope?.error?.nonEmpty
            ?? "PikPak 返回错误（\(code)）"
        return .api(code: code, message: message)
    }
}

// MARK: - Wire DTOs

struct PPFilesResponse: Decodable {
    let files: [PPFile]?
    let next_page_token: String?
}

struct PPFile: Decodable {
    let id: String
    let kind: String?
    let name: String
    let size: String?
    let mime_type: String?
    let thumbnail_link: String?
    let web_content_link: String?
    let modified_time: String?
    let medias: [PPMedia]?

    var asPikPakFile: PikPakFile {
        PikPakFile(id: id,
                   name: name,
                   isFolder: kind == "drive#folder",
                   size: Int64(size ?? "") ?? 0,
                   mimeType: mime_type,
                   thumbnailURL: thumbnail_link.flatMap(URL.init(string:)),
                   modifiedTime: PPFile.date(from: modified_time))
    }

    /// Prefer a streaming `medias` link (what PikPak's own player uses — it
    /// starts faster than the raw download URL): origin first to keep original
    /// quality, then the default rendition, then any. Falls back to
    /// `web_content_link` when the file has no media renditions.
    var bestPlaybackURL: URL? {
        let candidates = medias ?? []
        let pick = candidates.first(where: { $0.is_origin == true && $0.link?.url?.nonEmpty != nil })
            ?? candidates.first(where: { $0.is_default == true && $0.link?.url?.nonEmpty != nil })
            ?? candidates.first(where: { $0.link?.url?.nonEmpty != nil })
        if let s = pick?.link?.url?.nonEmpty, let url = URL(string: s) { return url }
        if let link = web_content_link?.nonEmpty, let url = URL(string: link) { return url }
        return nil
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func date(from string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

struct PPMedia: Decodable {
    let is_origin: Bool?
    let is_default: Bool?
    let resolution_name: String?
    let link: PPMediaLink?
}

struct PPMediaLink: Decodable {
    let url: String?
}

struct OfflineDownloadRequest: Encodable {
    let kind = "drive#file"
    let name: String
    let upload_type = "UPLOAD_TYPE_URL"
    let url: URLField
    let parent_id: String
    let folder_type: String
    struct URLField: Encodable { let url: String }
}

struct CreateFolderRequest: Encodable {
    let kind = "drive#folder"
    let parent_id: String
    let name: String
}

struct CreateFolderResponse: Decodable {
    let file: PPFile?
}

struct OfflineDownloadResponse: Decodable {
    let task: PPTask?
}

struct PPTask: Decodable {
    let id: String?
    let file_id: String?
    let file_name: String?
    let name: String?
    let phase: String?

    var asTask: PikPakTask {
        PikPakTask(id: id ?? "",
                   fileID: file_id ?? "",
                   name: file_name?.nonEmpty ?? name ?? "",
                   phase: phase ?? "")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

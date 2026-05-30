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

// MARK: - Drive client

public actor PikPakDrive {
    public static let shared = PikPakDrive()

    private let auth: PikPakAuth
    private let http: PikPakHTTPClient
    private let config: PikPakConfig

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

    // MARK: - Request plumbing

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw PikPakError.decoding(String(data: data, encoding: .utf8) ?? "\(error)") }
    }

    /// Performs an authorized GET, applying PikPak's error-code retry policy
    /// (token refresh / captcha re-sign) up to a small budget.
    private func authorizedGet(path: String, query: [String: String]) async throws -> Data {
        let url = buildURL(path: path, query: query)
        let action = PikPakCrypto.action(method: "GET", url: url)
        // Seed with the captcha token captured from the web login, so the first
        // call already carries a valid one (no salt-dependent re-sign needed).
        var captcha = await auth.currentCaptchaToken
        var triedRefresh = false
        var triedCaptcha = false

        while true {
            let token = try await auth.validAccessToken()
            var headers = ["Authorization": "Bearer \(token)",
                           "User-Agent": await auth.userAgent]
            if let device = await auth.currentDeviceID { headers["X-Device-ID"] = device }
            if !captcha.isEmpty { headers["X-Captcha-Token"] = captcha }

            let (data, status) = try await http.getJSON(url, headers: headers)
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

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

//
//  PikPakDriveTests.swift
//  IinaMagnetTests
//
//  Drive listing / playback-URL parsing + the error-code retry policy
//  (token refresh on 16, captcha re-sign on 9), driven through a queue stub.

import Testing
import Foundation
@testable import IinaMagnet

private struct StubReq: Sendable { let url: URL; let headers: [String: String]; let body: String }

/// Routes by URL-path substring to a FIFO queue of (status, json); the last
/// entry repeats. Records GET/POST requests for assertions.
private final class QueueStub: PikPakHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: [(status: Int, json: String)]]
    private(set) var gets: [StubReq] = []
    private(set) var posts: [StubReq] = []
    private(set) var deletes: [StubReq] = []

    init(_ queues: [String: [(status: Int, json: String)]]) { self.queues = queues }

    private func pop(_ url: URL) -> (Data, Int) {
        lock.withLock {
            for path in queues.keys where url.path.contains(path) {
                var arr = queues[path]!
                let r = arr.count > 1 ? arr.removeFirst() : arr[0]
                queues[path] = arr
                return (Data(r.json.utf8), r.status)
            }
            return (Data("{}".utf8), 404)
        }
    }

    func getJSON(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        lock.withLock { gets.append(StubReq(url: url, headers: headers, body: "")) }
        return pop(url)
    }
    func postJSON(_ url: URL, body: Data, headers: [String: String]) async throws -> (Data, Int) {
        let text = String(data: body, encoding: .utf8) ?? ""
        lock.withLock { posts.append(StubReq(url: url, headers: headers, body: text)) }
        return pop(url)
    }
    func deleteJSON(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        lock.withLock { deletes.append(StubReq(url: url, headers: headers, body: "")) }
        return pop(url)
    }
}

private func signedInAuth(_ stub: QueueStub,
                          recapturer: PikPakCaptchaRecapturing = FailingRecapturer()) -> PikPakAuth {
    let session = PikPakSession(accessToken: "acc", refreshToken: "ref", userID: "u-1",
                               deviceID: "0123456789abcdef0123456789abcdef",
                               expiresAt: Date().addingTimeInterval(7200))   // valid
    return PikPakAuth(config: .web, http: stub, store: InMemoryPikPakTokenStore(session),
                      recapturer: recapturer)
}

/// Stand-in recapturer that returns a fixed token (no web view in tests).
private struct StubRecapturer: PikPakCaptchaRecapturing {
    let token: String
    let device: String?
    func recapture(homeURL: URL, userAgent: String,
                   timeoutSeconds: Double) async throws -> (token: String, deviceID: String?) {
        (token, device)
    }
}

/// Recapturer that always fails — the default, so tests that don't exercise the
/// re-capture path behave as before (self-sign only).
private struct FailingRecapturer: PikPakCaptchaRecapturing {
    func recapture(homeURL: URL, userAgent: String,
                   timeoutSeconds: Double) async throws -> (token: String, deviceID: String?) {
        throw PikPakError.captchaRequired("no web view in tests")
    }
}

private let listJSON = """
{"files":[
  {"id":"folder1","kind":"drive#folder","name":"Anime"},
  {"id":"file1","kind":"drive#file","name":"ep01.mkv","size":"123456",
   "mime_type":"video/x-matroska","thumbnail_link":"https://t/1.jpg",
   "web_content_link":"https://dl.example/ep01.mkv"},
  {"id":"file2","kind":"drive#file","name":"poster.jpg","size":"42","mime_type":"image/jpeg"}
],"next_page_token":""}
"""

@Suite struct PikPakDriveTests {

    @Test func listParsesFilesFoldersAndVideoFlag() async throws {
        let stub = QueueStub(["/drive/v1/files": [(200, listJSON)]])
        let drive = PikPakDrive(auth: signedInAuth(stub), http: stub, config: .web)

        let files = try await drive.list()
        #expect(files.count == 3)

        let folder = try #require(files.first { $0.id == "folder1" })
        #expect(folder.isFolder)
        #expect(!folder.isVideo)

        let video = try #require(files.first { $0.id == "file1" })
        #expect(!video.isFolder)
        #expect(video.isVideo)
        #expect(video.size == 123456)
        #expect(video.thumbnailURL?.absoluteString == "https://t/1.jpg")

        let image = try #require(files.first { $0.id == "file2" })
        #expect(!image.isVideo)

        // Listing sends parent_id + the completed/not-trashed filter.
        let get = try #require(stub.gets.first)
        #expect(get.url.query?.contains("parent_id=") == true)
        #expect(get.headers["Authorization"] == "Bearer acc")
    }

    @Test func listFollowsPagination() async throws {
        let page1 = #"{"files":[{"id":"a","kind":"drive#file","name":"a.mp4"}],"next_page_token":"p2"}"#
        let page2 = #"{"files":[{"id":"b","kind":"drive#file","name":"b.mp4"}],"next_page_token":""}"#
        let stub = QueueStub(["/drive/v1/files": [(200, page1), (200, page2)]])
        let drive = PikPakDrive(auth: signedInAuth(stub), http: stub, config: .web)

        let files = try await drive.list()
        #expect(files.map(\.id) == ["a", "b"])
        #expect(stub.gets.count == 2)
        #expect(stub.gets[1].url.query?.contains("page_token=p2") == true)
    }

    @Test func playbackURLFallsBackToWebContentLinkWhenNoMedia() async throws {
        let detail = #"{"id":"file1","name":"ep.mkv","web_content_link":"https://dl/ep.mkv"}"#
        let stub = QueueStub(["/drive/v1/files/file1": [(200, detail)]])
        let drive = PikPakDrive(auth: signedInAuth(stub), http: stub, config: .web)
        let url = try await drive.playbackURL(fileID: "file1")
        #expect(url.absoluteString == "https://dl/ep.mkv")
    }

    @Test func playbackURLPrefersStreamingMediaOverDownload() async throws {
        // Both a download link and renditions present → use the origin stream.
        let detail = """
        {"id":"f","name":"ep.mkv","web_content_link":"https://dl/ep.mkv","medias":[
          {"is_default":true,"link":{"url":"https://stream/720"}},
          {"is_origin":true,"link":{"url":"https://stream/origin"}}
        ]}
        """
        let stub = QueueStub(["/drive/v1/files/f": [(200, detail)]])
        let drive = PikPakDrive(auth: signedInAuth(stub), http: stub, config: .web)
        let url = try await drive.playbackURL(fileID: "f")
        #expect(url.absoluteString == "https://stream/origin")
    }

    @Test func retriesAfterAccessTokenExpiry() async throws {
        let stub = QueueStub([
            "/drive/v1/files": [(200, #"{"error":"x","error_code":16}"#), (200, listJSON)],
            "/v1/auth/token": [(200, #"{"access_token":"acc2","refresh_token":"ref2","expires_in":7200,"sub":"u-1"}"#)],
        ])
        let drive = PikPakDrive(auth: signedInAuth(stub), http: stub, config: .web)

        let files = try await drive.list()
        #expect(files.count == 3)                       // succeeded after refresh
        #expect(stub.posts.contains { $0.url.path.contains("/v1/auth/token") })
        #expect(stub.gets.count == 2)
        #expect(stub.gets[1].headers["Authorization"] == "Bearer acc2")   // refreshed token used
    }

    @Test func capturedCaptchaTokenSentFromFirstRequest() async throws {
        let stub = QueueStub(["/drive/v1/files": [(200, listJSON)]])
        let auth = PikPakAuth(config: .web, http: stub, store: InMemoryPikPakTokenStore())
        await auth.adopt(PikPakWebCredentials(accessToken: "acc", refreshToken: "ref",
                                              userID: "u", deviceID: "dev", expiresIn: 7200,
                                              captchaToken: "CAP-LIVE"))
        let drive = PikPakDrive(auth: auth, http: stub, config: .web)

        _ = try await drive.list()
        #expect(stub.gets.count == 1)                                  // no code-9 round trip
        #expect(stub.gets.first?.headers["X-Captcha-Token"] == "CAP-LIVE")
    }

    @Test func retriesAfterCaptchaExpiry() async throws {
        let stub = QueueStub([
            "/drive/v1/files": [(200, #"{"error":"captcha_invalid","error_code":9}"#), (200, listJSON)],
            "/v1/shield/captcha/init": [(200, #"{"captcha_token":"ct-9"}"#)],
        ])
        let drive = PikPakDrive(auth: signedInAuth(stub), http: stub, config: .web)

        let files = try await drive.list()
        #expect(files.count == 3)
        #expect(stub.posts.contains { $0.url.path.contains("captcha/init") })
        // The retried GET carried the freshly minted captcha token.
        #expect(stub.gets[1].headers["X-Captcha-Token"] == "ct-9")
    }

    @Test func recapturesCaptchaWhenSelfSignRejected() async throws {
        // code 9 → self-signed captcha/init also rejected (rotated salts) →
        // fall back to a live re-capture, then the retry uses that token.
        let stub = QueueStub([
            "/drive/v1/files": [(200, #"{"error":"captcha_invalid","error_code":9}"#), (200, listJSON)],
            "/v1/shield/captcha/init": [(200, #"{"error":"captcha_invalid_sign","error_code":9}"#)],
        ])
        let auth = signedInAuth(stub, recapturer: StubRecapturer(token: "RECAP-LIVE", device: nil))
        let drive = PikPakDrive(auth: auth, http: stub, config: .web)

        let files = try await drive.list()
        #expect(files.count == 3)
        #expect(stub.posts.contains { $0.url.path.contains("captcha/init") })  // self-sign tried
        #expect(stub.gets.last?.headers["X-Captcha-Token"] == "RECAP-LIVE")    // re-capture used
    }

    @Test func captchaRequiredWhenBothSelfSignAndRecaptureFail() async {
        let stub = QueueStub([
            "/drive/v1/files": [(200, #"{"error":"captcha_invalid","error_code":9}"#)],
            "/v1/shield/captcha/init": [(200, #"{"error":"x","error_code":9}"#)],
        ])
        let drive = PikPakDrive(auth: signedInAuth(stub), http: stub, config: .web)  // FailingRecapturer
        do {
            _ = try await drive.list()
            Issue.record("expected captchaRequired")
        } catch let PikPakError.captchaRequired(msg) {
            #expect(msg.contains("重新登录"))
        } catch { Issue.record("wrong error: \(error)") }
    }

    @Test func recaptureAdoptsTokenAndUpdatesDeviceID() async throws {
        let auth = signedInAuth(QueueStub([:]),
                                recapturer: StubRecapturer(token: "CAP-NEW", device: "newdevice123"))
        let token = try await auth.recaptureCaptchaToken()
        #expect(token == "CAP-NEW")
        #expect(await auth.currentCaptchaToken == "CAP-NEW")
        #expect(await auth.currentDeviceID == "newdevice123")   // device kept in sync with captcha
    }

    @Test func offlineDownloadSavesIntoExistingPackFolder() async throws {
        // Root listing already has "Pack From Shared" → no folder creation.
        let folderList = #"{"files":[{"id":"pack1","kind":"drive#folder","name":"Pack From Shared"}],"next_page_token":""}"#
        let taskResp = #"{"task":{"id":"t1","file_id":"f1","file_name":"番剧.mkv","phase":"PHASE_TYPE_RUNNING"}}"#
        let stub = QueueStub(["/drive/v1/files": [(200, folderList), (200, taskResp)]])
        let drive = PikPakDrive(auth: signedInAuth(stub), http: stub, config: .web)

        let task = try await drive.offlineDownload(url: "magnet:?xt=urn:btih:ABC&dn=x", name: "x")
        #expect(task.fileID == "f1")
        #expect(stub.gets.count == 1)        // one list call to find the folder
        let post = try #require(stub.posts.first)
        #expect(post.body.contains("UPLOAD_TYPE_URL"))
        #expect(post.body.contains("magnet:?xt=urn:btih:ABC"))
        #expect(post.body.contains("\"parent_id\":\"pack1\""))   // saved into Pack From Shared
    }

    @Test func offlineDownloadCreatesPackFolderWhenMissing() async throws {
        let emptyRoot = #"{"files":[],"next_page_token":""}"#
        let created = #"{"file":{"id":"newpack","kind":"drive#folder","name":"Pack From Shared"}}"#
        let taskResp = #"{"task":{"id":"t1","file_id":"f1","name":"x","phase":"PHASE_TYPE_PENDING"}}"#
        let stub = QueueStub(["/drive/v1/files": [(200, emptyRoot), (200, created), (200, taskResp)]])
        let drive = PikPakDrive(auth: signedInAuth(stub), http: stub, config: .web)

        let task = try await drive.offlineDownload(url: "magnet:?xt=urn:btih:Z", name: "x")
        #expect(task.fileID == "f1")
        #expect(stub.posts.count == 2)       // create folder + add task
        #expect(stub.posts[0].body.contains("drive#folder"))
        #expect(stub.posts[1].body.contains("\"parent_id\":\"newpack\""))
    }

    @Test func nonRetryableErrorIsThrown() async {
        let stub = QueueStub([
            "/drive/v1/files": [(200, #"{"error":"too_many_requests","error_code":10,"error_description":"操作频繁"}"#)],
        ])
        let drive = PikPakDrive(auth: signedInAuth(stub), http: stub, config: .web)
        do {
            _ = try await drive.list()
            Issue.record("expected api error to be thrown")
        } catch let PikPakError.api(code, _) {
            #expect(code == 10)
        } catch { Issue.record("wrong error: \(error)") }
    }
}

@Suite struct PikPakTaskCenterTests {

    private let tasksJSON = """
    {"tasks":[
      {"id":"t1","file_id":"f1","file_name":"番剧 01.mkv","phase":"PHASE_TYPE_RUNNING",
       "progress":42,"file_size":"123456","params":{"url":"magnet:?xt=urn:btih:ABC"}},
      {"id":"t2","file_id":"f2","name":"fallback","phase":"PHASE_TYPE_ERROR",
       "message":"种子无法连接","progress":0}
    ],"next_page_token":""}
    """

    @Test func tasksParsePhaseProgressMessageAndSource() async throws {
        let stub = QueueStub(["/drive/v1/tasks": [(200, tasksJSON)]])
        let drive = PikPakDrive(auth: signedInAuth(stub), http: stub, config: .web)

        let tasks = try await drive.tasks()
        #expect(tasks.count == 2)

        let running = try #require(tasks.first { $0.id == "t1" })
        #expect(running.isRunning)
        #expect(running.progress == 42)
        #expect(running.fileSize == 123456)
        #expect(running.name == "番剧 01.mkv")
        #expect(running.sourceURL == "magnet:?xt=urn:btih:ABC")

        let failed = try #require(tasks.first { $0.id == "t2" })
        #expect(failed.isError)
        #expect(failed.message == "种子无法连接")
        #expect(failed.name == "fallback")        // falls back to `name` when no file_name
    }

    @Test func tasksRequestCarriesOfflineTypeAndPhaseFilter() async throws {
        let stub = QueueStub(["/drive/v1/tasks": [(200, #"{"tasks":[],"next_page_token":""}"#)]])
        let drive = PikPakDrive(auth: signedInAuth(stub), http: stub, config: .web)

        _ = try await drive.tasks()
        let get = try #require(stub.gets.first)
        let query = get.url.query ?? ""
        #expect(query.contains("type=offline"))
        #expect(get.url.path.contains("/drive/v1/tasks"))
        #expect((get.url.query?.removingPercentEncoding ?? "").contains("PHASE_TYPE_ERROR"))
    }

    @Test func deleteTaskHitsTasksEndpointWithTaskID() async throws {
        let stub = QueueStub(["/drive/v1/tasks": [(200, "{}")]])
        let drive = PikPakDrive(auth: signedInAuth(stub), http: stub, config: .web)

        try await drive.deleteTask(id: "t9")
        let del = try #require(stub.deletes.first)
        #expect(del.url.query?.contains("task_ids=t9") == true)
        #expect(del.url.query?.contains("delete_files=false") == true)
        #expect(del.headers["Authorization"] == "Bearer acc")
    }

    @Test func retryClearsOldTaskAndResubmitsSourceURL() async throws {
        let task = PikPakTask(id: "t1", fileID: "f1", name: "番剧", phase: "PHASE_TYPE_ERROR",
                              sourceURL: "magnet:?xt=urn:btih:ABC")
        let folderList = #"{"files":[{"id":"pack1","kind":"drive#folder","name":"Pack From Shared"}],"next_page_token":""}"#
        let taskResp = #"{"task":{"id":"t2","file_id":"f2","name":"番剧","phase":"PHASE_TYPE_RUNNING"}}"#
        let stub = QueueStub([
            "/drive/v1/tasks": [(200, "{}")],                    // delete old
            "/drive/v1/files": [(200, folderList), (200, taskResp)],  // find folder + add task
        ])
        let drive = PikPakDrive(auth: signedInAuth(stub), http: stub, config: .web)

        let new = try await drive.retryTask(task)
        #expect(new.fileID == "f2")
        #expect(stub.deletes.contains { $0.url.query?.contains("task_ids=t1") == true })
        #expect(stub.posts.last?.body.contains("magnet:?xt=urn:btih:ABC") == true)
    }

    @Test func retryWithoutSourceURLThrows() async {
        let task = PikPakTask(id: "t1", fileID: "f1", name: "x", phase: "PHASE_TYPE_ERROR")
        let stub = QueueStub(["/drive/v1/tasks": [(200, "{}")]])
        let drive = PikPakDrive(auth: signedInAuth(stub), http: stub, config: .web)
        do {
            _ = try await drive.retryTask(task)
            Issue.record("expected retry to throw without a source URL")
        } catch let PikPakError.api(code, _) {
            #expect(code == -6)
        } catch { Issue.record("wrong error: \(error)") }
    }
}

@Suite struct PikPakBrowsingTests {
    private func file(_ id: String, _ name: String, folder: Bool = false,
                      size: Int64 = 0, modified: Date? = nil) -> PikPakFile {
        PikPakFile(id: id, name: name, isFolder: folder, size: size,
                   mimeType: nil, thumbnailURL: nil, modifiedTime: modified)
    }

    @Test func foldersFirstThenNaturalNameOrder() {
        let input = [
            file("1", "ep10.mkv"),
            file("2", "Zeta", folder: true),
            file("3", "ep2.mkv"),
            file("4", "Anime", folder: true),
        ]
        let ordered = PikPakBrowsing.ordered(input)
        #expect(ordered.map(\.name) == ["Anime", "Zeta", "ep2.mkv", "ep10.mkv"])
    }

    @Test func sortBySizeDescendingKeepsFoldersFirst() {
        let input = [
            file("1", "small.mp4", size: 100),
            file("2", "Folder", folder: true),
            file("3", "big.mp4", size: 999),
        ]
        let ordered = PikPakBrowsing.ordered(input, by: PikPakSort(key: .size, ascending: false))
        #expect(ordered.map(\.name) == ["Folder", "big.mp4", "small.mp4"])
    }

    @Test func sortByModifiedDescending() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let input = [file("1", "older.mp4", modified: old), file("2", "newer.mp4", modified: new)]
        let ordered = PikPakBrowsing.ordered(input, by: PikPakSort(key: .modified, ascending: false))
        #expect(ordered.map(\.name) == ["newer.mp4", "older.mp4"])
    }
}

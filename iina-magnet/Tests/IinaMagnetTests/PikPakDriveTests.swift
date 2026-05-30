//
//  PikPakDriveTests.swift
//  IinaMagnetTests
//
//  Drive listing / playback-URL parsing + the error-code retry policy
//  (token refresh on 16, captcha re-sign on 9), driven through a queue stub.

import Testing
import Foundation
@testable import IinaMagnet

private struct StubReq: Sendable { let url: URL; let headers: [String: String] }

/// Routes by URL-path substring to a FIFO queue of (status, json); the last
/// entry repeats. Records GET/POST requests for assertions.
private final class QueueStub: PikPakHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: [(status: Int, json: String)]]
    private(set) var gets: [StubReq] = []
    private(set) var posts: [StubReq] = []

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
        lock.withLock { gets.append(StubReq(url: url, headers: headers)) }
        return pop(url)
    }
    func postJSON(_ url: URL, body: Data, headers: [String: String]) async throws -> (Data, Int) {
        lock.withLock { posts.append(StubReq(url: url, headers: headers)) }
        return pop(url)
    }
}

private func signedInAuth(_ stub: QueueStub) -> PikPakAuth {
    let session = PikPakSession(accessToken: "acc", refreshToken: "ref", userID: "u-1",
                               deviceID: "0123456789abcdef0123456789abcdef",
                               expiresAt: Date().addingTimeInterval(7200))   // valid
    return PikPakAuth(config: .web, http: stub, store: InMemoryPikPakTokenStore(session))
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

    @Test func playbackURLPrefersWebContentLink() async throws {
        let detail = #"{"id":"file1","name":"ep.mkv","web_content_link":"https://dl/ep.mkv"}"#
        let stub = QueueStub(["/drive/v1/files/file1": [(200, detail)]])
        let drive = PikPakDrive(auth: signedInAuth(stub), http: stub, config: .web)
        let url = try await drive.playbackURL(fileID: "file1")
        #expect(url.absoluteString == "https://dl/ep.mkv")
    }

    @Test func playbackURLFallsBackToOriginMedia() async throws {
        let detail = """
        {"id":"f","name":"ep.mkv","medias":[
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

@Suite struct PikPakBrowsingTests {
    private func file(_ id: String, _ name: String, folder: Bool) -> PikPakFile {
        PikPakFile(id: id, name: name, isFolder: folder, size: 0,
                   mimeType: nil, thumbnailURL: nil, modifiedTime: nil)
    }

    @Test func foldersFirstThenNaturalNameOrder() {
        let input = [
            file("1", "ep10.mkv", folder: false),
            file("2", "Zeta", folder: true),
            file("3", "ep2.mkv", folder: false),
            file("4", "Anime", folder: true),
        ]
        let ordered = PikPakBrowsing.ordered(input)
        #expect(ordered.map(\.name) == ["Anime", "Zeta", "ep2.mkv", "ep10.mkv"])
    }
}

//
//  Fetcher.swift
//  IinaMagnet
//
//  HTTP fetch layer for RSS subscriptions (Issue 12). Protocol-based so
//  Scheduler tests can inject a fake without going through URLSession.

import Foundation

public struct FetchResult: Sendable, Equatable {
    public let data: Data
    public let httpStatus: Int
    public let etag: String?
    public let lastModified: String?

    public init(data: Data, httpStatus: Int, etag: String?, lastModified: String?) {
        self.data = data
        self.httpStatus = httpStatus
        self.etag = etag
        self.lastModified = lastModified
    }
}

public enum FetchError: Error, Sendable {
    case http(status: Int)
    case transport(message: String)
}

public protocol Fetcher: Sendable {
    func fetch(url: URL, cookies: String?, headers: [String: String]) async throws -> FetchResult
}

public struct URLSessionFetcher: Fetcher {

    public let userAgent: String
    public let timeoutSeconds: TimeInterval

    public init(userAgent: String = "iina-magnet/0.1.0 (+https://github.com/iina/iina)",
                timeoutSeconds: TimeInterval = 30) {
        self.userAgent = userAgent
        self.timeoutSeconds = timeoutSeconds
    }

    public func fetch(url: URL, cookies: String?, headers: [String: String]) async throws -> FetchResult {
        var req = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        req.httpMethod = "GET"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/rss+xml,application/atom+xml,application/xml;q=0.9,*/*;q=0.5",
                     forHTTPHeaderField: "Accept")
        if let c = cookies, !c.isEmpty {
            req.setValue(c, forHTTPHeaderField: "Cookie")
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw FetchError.transport(message: "non-HTTP response")
            }
            if !(200..<300).contains(http.statusCode) {
                throw FetchError.http(status: http.statusCode)
            }
            return FetchResult(
                data: data,
                httpStatus: http.statusCode,
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified")
            )
        } catch let err as FetchError {
            throw err
        } catch {
            throw FetchError.transport(message: error.localizedDescription)
        }
    }
}

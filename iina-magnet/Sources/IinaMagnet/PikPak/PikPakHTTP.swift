//
//  PikPakHTTP.swift
//  IinaMagnet
//
//  POST-JSON transport for PikPak. Injectable so the auth flow tests run
//  against canned responses without touching the network.

import Foundation

public protocol PikPakHTTPClient: Sendable {
    /// POSTs `body` as JSON to `url` with `headers`; returns the raw response
    /// data and HTTP status. A non-2xx status is NOT thrown — the caller
    /// decodes PikPak's error envelope to surface a precise message.
    func postJSON(_ url: URL, body: Data, headers: [String: String]) async throws -> (Data, Int)

    /// GETs `url` (query already baked in) with `headers`; same non-throwing
    /// status contract as `postJSON`.
    func getJSON(_ url: URL, headers: [String: String]) async throws -> (Data, Int)
}

public struct URLSessionPikPakClient: PikPakHTTPClient {
    public let timeoutSeconds: TimeInterval

    public init(timeoutSeconds: TimeInterval = 15) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func postJSON(_ url: URL, body: Data,
                         headers: [String: String]) async throws -> (Data, Int) {
        var req = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }

        return try await send(req)
    }

    public func getJSON(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        var req = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        return try await send(req)
    }

    private func send(_ req: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw PikPakError.transport("non-HTTP response")
            }
            return (data, http.statusCode)
        } catch let error as PikPakError {
            throw error
        } catch {
            throw PikPakError.transport(error.localizedDescription)
        }
    }
}

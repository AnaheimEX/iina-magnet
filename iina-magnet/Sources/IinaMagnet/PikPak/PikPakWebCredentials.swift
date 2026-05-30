//
//  PikPakWebCredentials.swift
//  IinaMagnet
//
//  Extracts PikPak auth tokens from the web client's localStorage. The login UI
//  loads mypikpak.com in a web view, the user logs in there (PikPak handles
//  captcha / 2FA itself), and we read the resulting tokens back — the same
//  Bearer tokens the SPA uses for api-drive.mypikpak.com.
//
//  PikPak's exact localStorage layout isn't contractual, so the parser is
//  tolerant: it deep-scans every (possibly JSON-encoded) value for the first
//  object carrying both access_token and refresh_token. Pure + unit-tested.

import Foundation

public struct PikPakWebCredentials: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let userID: String
    public let deviceID: String?
    public let expiresIn: Int?

    public init(accessToken: String, refreshToken: String, userID: String,
                deviceID: String?, expiresIn: Int?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userID = userID
        self.deviceID = deviceID
        self.expiresIn = expiresIn
    }
}

public enum PikPakWebCredentialParser {

    /// Parses the JSON produced by `JSON.stringify(localStorage)` (a flat
    /// string→string map). Returns nil until a token pair is present.
    public static func parse(localStorageJSON json: String) -> PikPakWebCredentials? {
        guard let data = json.data(using: .utf8),
              let store = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Roots to deep-scan: the store itself (handles flat token keys) plus
        // every value that is itself a JSON blob (handles a nested credentials
        // object stored as a string).
        var roots: [Any] = [store]
        for value in store.values {
            if let s = value as? String, let s2 = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: s2) {
                roots.append(obj)
            }
        }
        let dicts = roots.flatMap(Self.allDicts)

        guard let cred = dicts.firstNonNil(Self.credential(from:)) else { return nil }
        // Device id can live elsewhere in the store; fall back to a wider scan.
        let device = cred.deviceID ?? Self.findDeviceID(in: dicts, store: store)
        return PikPakWebCredentials(accessToken: cred.accessToken,
                                    refreshToken: cred.refreshToken,
                                    userID: cred.userID,
                                    deviceID: device,
                                    expiresIn: cred.expiresIn)
    }

    // MARK: Scanning

    /// Every dictionary reachable from `json` (self + nested through arrays).
    private static func allDicts(_ json: Any) -> [[String: Any]] {
        var out: [[String: Any]] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                out.append(dict)
                for v in dict.values { walk(v) }
            } else if let arr = node as? [Any] {
                for v in arr { walk(v) }
            }
        }
        walk(json)
        return out
    }

    private static func credential(from dict: [String: Any]) -> PikPakWebCredentials? {
        guard let access = string(dict, ["access_token", "accessToken"]),
              let refresh = string(dict, ["refresh_token", "refreshToken"]) else { return nil }
        return PikPakWebCredentials(
            accessToken: access,
            refreshToken: refresh,
            userID: string(dict, ["sub", "user_id", "userId", "userid"]) ?? "",
            deviceID: string(dict, ["device_id", "deviceId", "deviceid"]),
            expiresIn: int(dict, ["expires_in", "expiresIn"]))
    }

    private static func findDeviceID(in dicts: [[String: Any]], store: [String: Any]) -> String? {
        for dict in dicts {
            if let d = string(dict, ["device_id", "deviceId", "deviceid"]) { return d }
        }
        // A top-level "...device..." key whose value looks like a device id.
        for (key, value) in store where key.lowercased().contains("device") {
            if let s = value as? String, isDeviceID(s) { return s }
        }
        return nil
    }

    private static func isDeviceID(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { $0.isHexDigit }
    }

    private static func string(_ dict: [String: Any], _ keys: [String]) -> String? {
        for k in keys {
            if let s = dict[k] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    private static func int(_ dict: [String: Any], _ keys: [String]) -> Int? {
        for k in keys {
            if let i = dict[k] as? Int { return i }
            if let d = dict[k] as? Double { return Int(d) }
            if let s = dict[k] as? String, let i = Int(s) { return i }
        }
        return nil
    }
}

private extension Array {
    func firstNonNil<T>(_ transform: (Element) -> T?) -> T? {
        for e in self { if let t = transform(e) { return t } }
        return nil
    }
}

//
//  PikPakCrypto.swift
//  IinaMagnet
//
//  Pure, deterministic signing primitives for PikPak auth. Kept free of any
//  network / state so the captcha-sign algorithm can be unit-tested in
//  isolation (the one part that must match PikPak's web client exactly).

import Foundation
import CryptoKit

enum PikPakCrypto {

    /// Lowercase hex md5 of a UTF-8 string.
    static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// PikPak captcha signature:
    ///   base = clientID + clientVersion + packageName + deviceID + timestamp(ms)
    ///   then md5-chain `base` through every salt (str = md5(str + salt))
    ///   sign = "1." + finalHash
    static func captchaSign(config: PikPakConfig,
                            deviceID: String,
                            timestampMillis: String) -> String {
        var str = config.clientID + config.clientVersion + config.packageName
                + deviceID + timestampMillis
        for salt in config.captchaSalts {
            str = md5Hex(str + salt)
        }
        return "1." + str
    }

    /// A stable-per-install device id: md5 of a random UUID (32 lowercase hex),
    /// matching the shape PikPak's clients use.
    static func randomDeviceID() -> String {
        md5Hex(UUID().uuidString)
    }

    /// The captcha "action" string, e.g. `POST:/v1/auth/signin` — HTTP method,
    /// a colon, then the URL's path.
    static func action(method: String, url: URL) -> String {
        method + ":" + url.path
    }

    /// Current epoch milliseconds as a string (the timestamp PikPak signs).
    static func timestampMillis(_ date: Date = Date()) -> String {
        String(Int64(date.timeIntervalSince1970 * 1000))
    }
}

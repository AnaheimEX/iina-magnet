//
//  PikPakCaptchaRecapturer.swift
//  IinaMagnet
//
//  Silent captcha re-capture. When a drive call reports its captcha token
//  expired (error_code 9) and a self-signed replacement is rejected — which
//  happens whenever PikPak has rotated the captcha salts in PikPakConfig — we
//  briefly load the PikPak web client offscreen. Its JS computes a valid
//  captcha_sign with the *current* salts and attaches a fresh x-captcha-token
//  to its own API calls; we hook fetch/XHR to grab it (the same mechanism the
//  login web view uses). This avoids forcing the user to log in again.
//
//  Injectable behind a protocol so PikPakAuth's retry path is unit-testable
//  without a web view.

import Foundation

/// Re-captures a fresh, PikPak-minted captcha token (and the device id it is
/// bound to) by observing the web client. Throws on timeout / failure.
public protocol PikPakCaptchaRecapturing: Sendable {
    func recapture(homeURL: URL, userAgent: String,
                   timeoutSeconds: Double) async throws -> (token: String, deviceID: String?)
}

public enum PikPakCaptcha {
    /// The platform's default recapturer (WebKit-backed where available).
    public static var defaultRecapturer: PikPakCaptchaRecapturing {
        #if canImport(WebKit)
        WebViewCaptchaRecapturer()
        #else
        UnavailableCaptchaRecapturer()
        #endif
    }
}

/// Used when WebKit isn't available: there's no way to re-capture, so callers
/// fall back to prompting a fresh login.
struct UnavailableCaptchaRecapturer: PikPakCaptchaRecapturing {
    func recapture(homeURL: URL, userAgent: String,
                   timeoutSeconds: Double) async throws -> (token: String, deviceID: String?) {
        throw PikPakError.captchaRequired("PikPak 验证已过期，请重新登录 PikPak。")
    }
}

#if canImport(WebKit)
import WebKit

/// Default implementation: runs the shared offscreen probe (`PikPakWebProbe`)
/// against the PikPak web client in the *persistent* data store, so the SPA
/// boots already-logged-in from the login sheet's cookies, makes authenticated
/// calls, and we lift the fresh `x-captcha-token` off its own traffic.
public struct WebViewCaptchaRecapturer: PikPakCaptchaRecapturing {
    public init() {}

    public func recapture(homeURL: URL, userAgent: String,
                          timeoutSeconds: Double) async throws -> (token: String, deviceID: String?) {
        // The drive route (not the marketing home page) is what triggers the
        // authenticated API calls a captcha token rides on.
        let result = try await PikPakWebProbe.run(goal: .captchaToken,
                                                 url: PikPakSessionRestore.restoreURL(),
                                                 userAgent: userAgent,
                                                 timeoutSeconds: timeoutSeconds)
        guard let token = result.captchaToken, !token.isEmpty else {
            throw PikPakError.captchaRequired("PikPak 验证刷新超时，请重新登录 PikPak。")
        }
        return (token, result.deviceID)
    }
}
#endif

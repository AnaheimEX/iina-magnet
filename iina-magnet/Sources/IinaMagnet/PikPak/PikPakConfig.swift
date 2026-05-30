//
//  PikPakConfig.swift
//  IinaMagnet
//
//  PikPak client identity + captcha-signing parameters for the *web* client.
//
//  ⚠️  EDIT THE `web` VALUES BELOW if login starts failing with captcha / sign
//  errors. PikPak has no public API; these values replicate its web client and
//  must match it byte-for-byte or `/v1/shield/captcha/init` rejects the request.
//  PikPak periodically rotates `captchaSalts` and bumps `clientVersion` when it
//  ships a new web client. Reference for the current values: the `Web*`
//  constants + `WebAlgorithms` in the alist / OpenList pikpak driver
//  (drivers/pikpak/util.go). Used only to reach the signed-in user's own drive,
//  the same way rclone/alist do.

import Foundation

public struct PikPakConfig: Sendable {
    public var clientID: String
    public var clientSecret: String
    public var clientVersion: String
    public var packageName: String
    /// Ordered captcha-sign salts. Order is significant — md5 is *chained*
    /// over them, so reordering or editing any entry changes every signature.
    public var captchaSalts: [String]
    public var userAgent: String

    // Endpoints (auth lives on the `.net` host; the drive API is `.com`).
    public var captchaInitURL: URL
    public var signInURL: URL
    public var tokenURL: URL
    /// Sent in the captcha-init request; a fixed constant from the web client.
    public var redirectURI: String

    public init(clientID: String, clientSecret: String, clientVersion: String,
                packageName: String, captchaSalts: [String], userAgent: String,
                captchaInitURL: URL, signInURL: URL, tokenURL: URL, redirectURI: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.clientVersion = clientVersion
        self.packageName = packageName
        self.captchaSalts = captchaSalts
        self.userAgent = userAgent
        self.captchaInitURL = captchaInitURL
        self.signInURL = signInURL
        self.tokenURL = tokenURL
        self.redirectURI = redirectURI
    }

    /// The public PikPak **web** client. These are the values to keep in sync.
    public static let web = PikPakConfig(
        clientID: "YUMx5nI8ZU8Ap8pm",
        clientSecret: "dbw2OtmVEeuUvIptb1Coyg",
        clientVersion: "2.0.0",
        packageName: "mypikpak.com",
        captchaSalts: [
            "C9qPpZLN8ucRTaTiUMWYS9cQvWOE",
            "+r6CQVxjzJV6LCV",
            "F",
            "pFJRC",
            "9WXYIDGrwTCz2OiVlgZa90qpECPD6olt",
            "/750aCr4lm/Sly/c",
            "RB+DT/gZCrbV",
            "",
            "CyLsf7hdkIRxRm215hl",
            "7xHvLi2tOYP0Y92b",
            "ZGTXXxu8E/MIWaEDB+Sm/",
            "1UI3",
            "E7fP5Pfijd+7K+t6Tg/NhuLq0eEUVChpJSkrKxpO",
            "ihtqpG6FMt65+Xk+tWUH2",
            "NhXXU9rg4XXdzo7u5o",
        ],
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                   "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        captchaInitURL: URL(string: "https://user.mypikpak.net/v1/shield/captcha/init")!,
        signInURL: URL(string: "https://user.mypikpak.net/v1/auth/signin")!,
        tokenURL: URL(string: "https://user.mypikpak.net/v1/auth/token")!,
        redirectURI: "xlaccsdk01://xbase.cloud/callback?state=harbor")
}

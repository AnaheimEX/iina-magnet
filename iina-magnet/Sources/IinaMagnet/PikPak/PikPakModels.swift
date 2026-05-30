//
//  PikPakModels.swift
//  IinaMagnet
//
//  Wire DTOs for PikPak auth. Field names are snake_case to mirror the JSON
//  exactly (same convention as the Bangumi provider's response structs), so no
//  key strategy is needed.

import Foundation

// MARK: Requests

struct CaptchaInitRequest: Encodable {
    let action: String
    let captcha_token: String
    let client_id: String
    let device_id: String
    let meta: [String: String]
    let redirect_uri: String
}

struct SignInRequest: Encodable {
    let captcha_token: String
    let client_id: String
    let client_secret: String
    let username: String
    let password: String
}

struct RefreshTokenRequest: Encodable {
    let client_id: String
    let client_secret: String
    let grant_type: String
    let refresh_token: String
}

// MARK: Responses

struct CaptchaInitResponse: Decodable {
    let captcha_token: String?
    let expires_in: Int?
    /// Non-empty when PikPak demands interactive (browser) human verification.
    let url: String?
}

struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Int?
    let token_type: String?
    let sub: String?          // PikPak user id
}

/// PikPak's error envelope. All optional so it also decodes cleanly (to "no
/// error") against a success body.
struct PikPakErrorResponse: Decodable {
    let error: String?
    let error_code: Int?
    let error_description: String?
}

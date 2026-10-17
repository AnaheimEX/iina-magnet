//
//  PikPakError.swift
//  IinaMagnet
//

import Foundation

public enum PikPakError: Error, Sendable, Equatable {
    /// Username or password was empty.
    case missingCredentials
    /// PikPak demands interactive human verification, or no captcha token came
    /// back. The string carries a user-facing hint (and a verify URL if any).
    case captchaRequired(String)
    /// PikPak returned a structured error (e.g. wrong password, invalid token).
    case api(code: Int, message: String)
    /// Non-2xx with no decodable error body.
    case http(status: Int)
    /// Networking / transport failure.
    case transport(String)
    /// A call needed a session but none exists.
    case notAuthenticated
    /// Response body could not be decoded; payload echoed for diagnosis.
    case decoding(String)
}

extension PikPakError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingCredentials:      return "请输入账号和密码"
        case .captchaRequired(let s):  return s
        case .api(_, let message):     return message
        case .http(let status):        return "网络错误（HTTP \(status)）"
        case .transport(let detail):   return "网络连接失败：\(detail)"
        case .notAuthenticated:        return "尚未登录 PikPak"
        case .decoding:                return "无法解析 PikPak 返回的数据"
        }
    }
}

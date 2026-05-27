//
//  DisclaimerAcceptance.swift
//  IinaMagnet
//
//  Records the user's acceptance of a specific disclaimer version.
//  One row per accepted version; absence of a row for the current version
//  means the user must see the disclaimer again.

import Foundation
import SwiftData

@Model
public final class DisclaimerAcceptance {

    @Attribute(.unique) public var version: String
    public var acceptedAt: Date

    public init(version: String, acceptedAt: Date) {
        self.version = version
        self.acceptedAt = acceptedAt
    }
}

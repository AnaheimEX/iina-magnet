//
//  DisclaimerCoordinator.swift
//  IinaMagnet
//
//  Owns the disclaimer-acceptance state machine.
//  - `currentVersion` is hardcoded; bump it whenever the disclaimer text
//    materially changes (the user is re-prompted).
//  - `needsAcceptance()` is the gate the launch flow consults before
//    presenting the modal sheet.

import Foundation
import SwiftData
import OSLog

@MainActor
@Observable
public final class DisclaimerCoordinator {

    /// Bumped whenever the disclaimer text materially changes.
    /// Source of truth for the two markdown files in `Resources/`.
    public static let currentVersion = "2026-05-26"

    private static let logger = Logger(subsystem: "iina-magnet", category: "disclaimer")

    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// True if the user has not yet accepted the current disclaimer version.
    public func needsAcceptance() -> Bool {
        let target = Self.currentVersion
        let descriptor = FetchDescriptor<DisclaimerAcceptance>(
            predicate: #Predicate { $0.version == target }
        )
        do {
            return try context.fetchCount(descriptor) == 0
        } catch {
            Self.logger.error("needsAcceptance fetch failed: \(error.localizedDescription, privacy: .public); treating as needs-acceptance")
            return true
        }
    }

    /// Records acceptance of `currentVersion` at the current time.
    public func accept() throws {
        let record = DisclaimerAcceptance(version: Self.currentVersion, acceptedAt: .now)
        context.insert(record)
        try context.save()
        Self.logger.info("disclaimer accepted: version=\(Self.currentVersion)")
    }
}

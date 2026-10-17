// Persists disclaimer acceptance independently of the cloud-service UI.
import Foundation
import SwiftData
import OSLog

public final class DisclaimerStore {

    private static let logger = Logger(subsystem: "iina-magnet", category: "disclaimer-store")

    /// Shared production instance, backed by a file in Application Support.
    public static let shared = DisclaimerStore(inMemory: false)

    /// Convenience for unit tests — no disk writes, no leakage between cases.
    public static func inMemory() -> DisclaimerStore {
        DisclaimerStore(inMemory: true)
    }

    public let container: ModelContainer

    private init(inMemory: Bool) {
        let schema = Schema([DisclaimerAcceptance.self])

        do {
            if inMemory {
                let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                container = try ModelContainer(for: schema, configurations: [config])
            } else {
                let url = Self.storeURL()
                let config = ModelConfiguration(schema: schema, url: url)
                container = try ModelContainer(for: schema, configurations: [config])
            }
            Self.logger.info("ModelContainer ready (inMemory=\(inMemory))")
        } catch {
            Self.logger.fault("Failed to create ModelContainer: \(error.localizedDescription, privacy: .public)")
            fatalError("iina-magnet failed to open its database: \(error)")
        }
    }

    /// Retain the original store filename to preserve existing disclaimer acceptance.
    /// Creates the directory if needed.
    private static func storeURL() -> URL {
        let fm = FileManager.default
        let appSupport = try! fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true)
        let dir = appSupport.appendingPathComponent("iina-magnet", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("Library.sqlite", isDirectory: false)
    }
}

//
//  CompletionPipeline.swift
//  IinaMagnet
//
//  Listens for TorrentEvent.torrentFinished and:
//    1) Optionally moves the torrent's downloaded files from cache →
//       AppSettings.completedDirectory (under a per-torrent subdirectory)
//    2) Runs SubtitleExtractor.plan + execute on the resulting directory
//    3) Posts a UserNotifications "X completed" alert
//    4) Updates the TorrentTask.savePath to point at the new location

import Foundation
import SwiftData
import OSLog
import UserNotifications

public actor CompletionPipeline {

    public static let shared = CompletionPipeline()

    private static let logger = Logger(subsystem: "iina-magnet", category: "completion")

    private let torrentManager: TorrentManager
    private let persistence: PersistenceController
    private var modelContext: ModelContext?
    private var listenerTask: Task<Void, Never>?
    private var didStart = false

    public init(torrentManager: TorrentManager = .shared,
                persistence: PersistenceController = .shared) {
        self.torrentManager = torrentManager
        self.persistence = persistence
    }

    public func start() async {
        guard !didStart else { return }
        didStart = true
        modelContext = ModelContext(persistence.container)
        await requestNotificationAuthorizationIfNeeded()
        startListening()
        Self.logger.info("CompletionPipeline started")
    }

    public func shutdown() async {
        guard didStart else { return }
        didStart = false
        listenerTask?.cancel()
        listenerTask = nil
        Self.logger.info("CompletionPipeline shutdown")
    }

    // MARK: Listener

    private func startListening() {
        let stream = torrentManager.events()
        listenerTask = Task { [weak self] in
            for await event in stream {
                if Task.isCancelled { return }
                if case let .torrentFinished(hash) = event {
                    await self?.handleFinished(infoHash: hash)
                }
            }
        }
    }

    private func handleFinished(infoHash: InfoHash) async {
        guard let ctx = modelContext else { return }
        let hashHex = infoHash.hex
        let pred = #Predicate<TorrentTask> { $0.infoHash == hashHex }
        guard let task = try? ctx.fetch(FetchDescriptor(predicate: pred)).first else { return }

        let sourceDir = task.savePath
        Self.logger.info("torrent \(hashHex, privacy: .public) finished at \(sourceDir.path, privacy: .public)")

        let autoMove = await MainActor.run { AppSettings.shared.autoMoveOnCompletion }
        var destinationDir: URL = sourceDir
        if autoMove {
            let completedRoot = await MainActor.run { AppSettings.shared.completedDirectory }
            do {
                destinationDir = try moveCompletedDirectory(sourceDir, into: completedRoot, displayName: task.displayName)
                task.savePath = destinationDir
                try ctx.save()
            } catch {
                Self.logger.error("move failed (\(error.localizedDescription, privacy: .public)); leaving in cache")
            }
        }

        runSubtitleExtraction(rootDir: destinationDir)
        await postNotification(name: task.displayName, at: destinationDir)
    }

    // MARK: File move

    private func moveCompletedDirectory(_ source: URL, into completedRoot: URL, displayName: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: completedRoot, withIntermediateDirectories: true)
        var target = completedRoot.appendingPathComponent(source.lastPathComponent, isDirectory: true)

        // Avoid clobbering an existing directory.
        var counter = 1
        while fm.fileExists(atPath: target.path) {
            target = completedRoot.appendingPathComponent("\(source.lastPathComponent)_\(counter)", isDirectory: true)
            counter += 1
            if counter > 100 { throw NSError(domain: "CompletionPipeline", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: "too many name collisions"]) }
        }
        try fm.moveItem(at: source, to: target)
        Self.logger.info("moved → \(target.path, privacy: .public)")
        return target
    }

    // MARK: Subtitle extraction

    private func runSubtitleExtraction(rootDir: URL) {
        do {
            let plans = try SubtitleExtractor.plan(rootDirectory: rootDir)
            try SubtitleExtractor.execute(plans)
            let copies = plans.flatMap(\.copies).count
            Self.logger.info("subtitle extraction at \(rootDir.path, privacy: .public): \(copies) sidecar(s) written")
        } catch {
            Self.logger.error("subtitle extraction failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Notifications

    private func requestNotificationAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Self.logger.debug("notification authorization request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func postNotification(name: String, at directory: URL) async {
        let content = UNMutableNotificationContent()
        content.title = "Download complete"
        content.body = name
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Self.logger.debug("notification post failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

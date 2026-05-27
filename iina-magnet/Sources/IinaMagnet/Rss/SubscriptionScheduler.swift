//
//  SubscriptionScheduler.swift
//  IinaMagnet
//
//  Drives the RSS poll loop (Issue 13). Actor-isolated; one Task per source.
//  Pumps Fetcher → FeedParser → RssRuleEngine → TorrentManager.addMagnet.

import Foundation
import SwiftData
import OSLog

public actor SubscriptionScheduler {

    public static let shared: SubscriptionScheduler = SubscriptionScheduler()

    private static let logger = Logger(subsystem: "iina-magnet", category: "rss")

    private let persistence: PersistenceController
    private let fetcher: any Fetcher
    private let torrentManager: TorrentManager
    private var modelContext: ModelContext?
    private var sourceTasks: [PersistentIdentifier: Task<Void, Never>] = [:]
    private var didStart = false

    /// Where downloaded torrents go before the CompletionPipeline (Issue 17) moves them.
    public var cacheDirectory: URL

    public init(persistence: PersistenceController = .shared,
                fetcher: any Fetcher = URLSessionFetcher(),
                torrentManager: TorrentManager = .shared,
                cacheDirectory: URL? = nil) {
        self.persistence = persistence
        self.fetcher = fetcher
        self.torrentManager = torrentManager
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory()
    }

    private static func defaultCacheDirectory() -> URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("iina-magnet", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
    }

    // MARK: Lifecycle

    public func start() async {
        guard !didStart else { return }
        didStart = true
        modelContext = ModelContext(persistence.container)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        await rescheduleAll()
        Self.logger.info("SubscriptionScheduler started; cacheDir=\(self.cacheDirectory.path, privacy: .public)")
    }

    public func shutdown() async {
        guard didStart else { return }
        didStart = false
        for (_, t) in sourceTasks { t.cancel() }
        sourceTasks.removeAll()
        Self.logger.info("SubscriptionScheduler shutdown")
    }

    // MARK: Public API

    /// Trigger a one-shot fetch for a source, outside its polling cadence.
    public func pollNow(sourceId: PersistentIdentifier) async {
        guard let ctx = modelContext else { return }
        guard let source = try? ctx.fetch(FetchDescriptor<SubscriptionSource>(
            predicate: #Predicate { $0.persistentModelID == sourceId }
        )).first else { return }
        await pollOnce(source)
    }

    /// Re-evaluate enabled/disabled state of all sources and (re)schedule.
    /// Call after adding/removing/toggling sources from the UI.
    public func rescheduleAll() async {
        guard let ctx = modelContext else { return }
        let sources = (try? ctx.fetch(FetchDescriptor<SubscriptionSource>())) ?? []

        // Cancel tasks for sources that no longer exist or are disabled.
        let activeIds = Set(sources.filter(\.enabled).map(\.persistentModelID))
        for (id, task) in sourceTasks where !activeIds.contains(id) {
            task.cancel()
            sourceTasks.removeValue(forKey: id)
        }

        // Start tasks for newly-enabled sources.
        for source in sources where source.enabled && sourceTasks[source.persistentModelID] == nil {
            let sid = source.persistentModelID
            sourceTasks[sid] = Task { [weak self] in
                await self?.runSourceLoop(sourceId: sid)
            }
        }
    }

    // MARK: Per-source loop

    private func runSourceLoop(sourceId: PersistentIdentifier) async {
        while !Task.isCancelled {
            guard let ctx = modelContext else { return }
            guard let source = try? ctx.fetch(FetchDescriptor<SubscriptionSource>(
                predicate: #Predicate { $0.persistentModelID == sourceId }
            )).first else { return }   // source deleted

            if !source.enabled { return }

            // Compute next-run time.
            let last = source.lastPolledAt ?? .distantPast
            let interval = max(60, source.pollIntervalSeconds)  // floor 60s
            let nextRun = last.addingTimeInterval(TimeInterval(interval))
            let delay = max(0, nextRun.timeIntervalSinceNow)
            // Jitter ±10% to avoid thundering herd across sources.
            let jittered = delay * Double.random(in: 0.9...1.1)
            try? await Task.sleep(nanoseconds: UInt64(jittered * 1_000_000_000))
            if Task.isCancelled { return }

            await pollOnce(source)
        }
    }

    private func pollOnce(_ source: SubscriptionSource) async {
        guard let ctx = modelContext else { return }
        let url = source.url
        Self.logger.debug("polling \(url, privacy: .public)")

        do {
            let result = try await fetcher.fetch(url: url,
                                                 cookies: source.cookieHeader,
                                                 headers: source.customHeaders)
            let parsed = try FeedParser.parse(result.data)
            let newItems = persistNewItems(parsed.items, source: source, ctx: ctx)
            let matches = applyRules(newItems, source: source, ctx: ctx)
            await enqueueDownloads(for: matches, items: newItems, ctx: ctx)

            source.lastPolledAt = .now
            source.lastPollResult = .success(itemCount: parsed.items.count)
            try? ctx.save()
            Self.logger.info("\(url, privacy: .public): \(parsed.items.count) items, \(matches.count) matches")
        } catch {
            source.lastPolledAt = .now
            source.lastPollResult = .error(message: String(describing: error))
            try? ctx.save()
            Self.logger.error("poll failed for \(url, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Inserts only items whose guid we haven't seen.
    private func persistNewItems(_ items: [ParsedFeedItem],
                                 source: SubscriptionSource,
                                 ctx: ModelContext) -> [FeedItem] {
        var inserted: [FeedItem] = []
        for parsed in items {
            let guid = parsed.guid
            let existing = try? ctx.fetch(FetchDescriptor<FeedItem>(
                predicate: #Predicate { $0.guid == guid }
            )).first
            if existing != nil { continue }

            let item = FeedItem(
                guid: parsed.guid,
                title: parsed.title,
                enclosureURL: parsed.enclosureURL,
                publishedAt: parsed.publishedAt ?? .now,
                source: source
            )
            ctx.insert(item)
            inserted.append(item)
        }
        return inserted
    }

    private func applyRules(_ items: [FeedItem],
                            source: SubscriptionSource,
                            ctx: ModelContext) -> [EngineMatch] {
        let engineItems = items.map { EngineFeedItem(guid: $0.guid, title: $0.title) }
        let engineRules: [EngineRule] = source.rules.compactMap { rule in
            EngineRule(
                id: ruleKey(rule),
                name: rule.name,
                include: rule.include,
                exclude: rule.exclude,
                regex: rule.regex,
                caseSensitive: rule.caseSensitive,
                enabled: rule.enabled
            )
        }
        let matches = RssRuleEngine.evaluate(items: engineItems, rules: engineRules)

        // Mark matched FeedItem rows and bump rule hit counters.
        let rulesByKey = Dictionary(uniqueKeysWithValues: source.rules.map { (ruleKey($0), $0) })
        for match in matches {
            if let item = items.first(where: { $0.guid == match.itemGuid }) {
                item.matched = true
                if let rule = rulesByKey[match.ruleId] {
                    item.matchedRule = rule
                    rule.hitCount += 1
                }
            }
        }
        return matches
    }

    private func enqueueDownloads(for matches: [EngineMatch],
                                  items: [FeedItem],
                                  ctx: ModelContext) async {
        for match in matches {
            guard let item = items.first(where: { $0.guid == match.itemGuid }) else { continue }
            let savePath = cacheDirectory.appendingPathComponent(safePathComponent(item.title), isDirectory: true)
            try? FileManager.default.createDirectory(at: savePath, withIntermediateDirectories: true)

            let urlStr = item.enclosureURL.absoluteString
            do {
                if urlStr.lowercased().hasPrefix("magnet:") {
                    _ = try await torrentManager.addMagnet(urlStr, savePath: savePath)
                } else {
                    // Future: HTTP fetch .torrent file then addTorrentFile.
                    Self.logger.warning("non-magnet enclosure not yet supported: \(urlStr, privacy: .public)")
                }
            } catch {
                Self.logger.error("addMagnet failed for \(urlStr, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func ruleKey(_ rule: SubscriptionRule) -> String {
        rule.persistentModelID.entityName + "/" + String(describing: rule.persistentModelID)
    }

    private func safePathComponent(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\"\\")
        return String(s.unicodeScalars.map { bad.contains($0) ? Character("_") : Character($0) })
            .trimmingCharacters(in: .whitespaces)
    }
}

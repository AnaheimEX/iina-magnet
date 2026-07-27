import Darwin
import Foundation

public enum BundledPluginAtomicRenameError: Error, Equatable, Sendable {
    case destinationExists
    case crossDevice
    case unsupported
    case posix(Int32)
}

public protocol BundledPluginAtomicRenamer {
    func renameExclusive(from source: URL, to destination: URL) throws
    func swap(_ first: URL, _ second: URL) throws
}

public struct DarwinBundledPluginAtomicRenamer: BundledPluginAtomicRenamer, Sendable {
    public init() {}

    public func renameExclusive(from source: URL, to destination: URL) throws {
        guard renameatx_np(AT_FDCWD, source.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw mapErrno(errno)
        }
    }

    public func swap(_ first: URL, _ second: URL) throws {
        guard renameatx_np(AT_FDCWD, first.path, AT_FDCWD, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw mapErrno(errno)
        }
    }

    private func mapErrno(_ code: Int32) -> BundledPluginAtomicRenameError {
        switch code {
        case EEXIST: .destinationExists
        case EXDEV: .crossDevice
        case ENOTSUP, EINVAL: .unsupported
        default: .posix(code)
        }
    }
}

public protocol BundledPluginArchiveExtractor {
    func extract(archiveData: Data, to destination: URL, fileSystem: any BundledPluginFileSystem) throws -> [BundledPluginArchiveEntry]
}

public struct DittoBundledPluginArchiveExtractor: BundledPluginArchiveExtractor, Sendable {
    public init() {}

    public func extract(archiveData: Data, to destination: URL, fileSystem: any BundledPluginFileSystem) throws -> [BundledPluginArchiveEntry] {
        let archiveURL = destination.deletingLastPathComponent().appendingPathComponent(".anime4k.\(UUID().uuidString).iinaplgz")
        try fileSystem.writeDataAtomicallyAndSync(archiveData, to: archiveURL)
        defer { try? fileSystem.removeItem(at: archiveURL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destination.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw BundledPluginCoreError.extractionFailed(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8) ?? "ditto exit \(process.terminationStatus)"
            throw BundledPluginCoreError.extractionFailed(detail)
        }
        return try inspectExtractedFiles(at: destination)
    }

    private func inspectExtractedFiles(at root: URL) throws -> [BundledPluginArchiveEntry] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else { throw BundledPluginCoreError.extractionFailed("cannot enumerate extracted archive") }
        var entries: [BundledPluginArchiveEntry] = []
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { throw BundledPluginCoreError.invalidArchiveEntry("extracted path escaped staging") }
            let relative = String(path.dropFirst(prefix.count))
            if values.isDirectory == true { continue }
            let kind: BundledPluginArchiveEntryKind = values.isSymbolicLink == true ? .symbolicLink : (values.isRegularFile == true ? .file : .other)
            let data = kind == .file ? try Data(contentsOf: url, options: [.mappedIfSafe]) : Data()
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
            entries.append(.init(
                path: relative,
                kind: kind,
                size: values.fileSize ?? data.count,
                sha256: kind == .file ? BundledPluginTrustedVerifier.sha256Prefixed(data) : nil,
                posixPermissions: permissions
            ))
        }
        return entries.sorted { $0.path < $1.path }
    }
}

public struct BundledPluginAdapterState: Equatable, Sendable {
    public let enabled: Bool?
    public let order: [String]

    public init(enabled: Bool?, order: [String]) {
        self.enabled = enabled
        self.order = order
    }
}

public enum BundledPluginTransactionStatus: String, Codable, Sendable {
    case noChange
    case committedFreshInstall
    case committedReplacement
    case recoveredKeepingCanonical
    case recoveredFreshInstall
    case recoveredPriorPackage
    case needsReinventory
}

public struct BundledPluginTransactionOutcome: Equatable, Sendable {
    public let status: BundledPluginTransactionStatus
    public let needsInventoryReload: Bool
    public let adapterState: BundledPluginAdapterState

    public init(status: BundledPluginTransactionStatus, needsInventoryReload: Bool, adapterState: BundledPluginAdapterState) {
        self.status = status
        self.needsInventoryReload = needsInventoryReload
        self.adapterState = adapterState
    }
}

public enum BundledPluginTransactionCheckpoint: String, Codable, Sendable {
    case beforeStaging
    case afterVerification
    case beforeCommit
    case afterCommit
    case duringRecovery
    case beforeCleanup
}

public struct BundledPluginInjectedCrash: Error, Equatable, Sendable {
    public let checkpoint: BundledPluginTransactionCheckpoint
    public init(_ checkpoint: BundledPluginTransactionCheckpoint) { self.checkpoint = checkpoint }
}

public struct BundledPluginTransactionConfiguration: Equatable, Sendable {
    public let root: URL
    public let canonicalName: String
    public let stagingName: String
    public let priorName: String
    public let journalName: String
    public let adapterState: BundledPluginAdapterState

    public init(
        root: URL,
        canonicalName: String = "io.iina.magnet.anime4k.iinaplugin",
        stagingName: String = ".io.iina.magnet.anime4k.stage",
        priorName: String = ".io.iina.magnet.anime4k.prior",
        journalName: String = ".io.iina.magnet.anime4k.transaction.json",
        adapterState: BundledPluginAdapterState
    ) throws {
        guard !root.path.isEmpty, root.isFileURL else {
            throw BundledPluginCoreError.invalidTransactionConfiguration("root must be a file URL")
        }
        guard Self.isLoaderVisible(canonicalName) else {
            throw BundledPluginCoreError.invalidTransactionConfiguration("canonical name must be loader-visible")
        }
        for name in [stagingName, priorName, journalName] where !Self.isHiddenAndLoaderInvisible(name) {
            throw BundledPluginCoreError.invalidTransactionConfiguration("transaction paths must be hidden and loader-invisible")
        }
        guard Set([canonicalName, stagingName, priorName, journalName]).count == 4 else {
            throw BundledPluginCoreError.invalidTransactionConfiguration("transaction paths must be unique")
        }
        self.root = root.standardizedFileURL
        self.canonicalName = canonicalName
        self.stagingName = stagingName
        self.priorName = priorName
        self.journalName = journalName
        self.adapterState = adapterState
    }

    public var canonicalURL: URL { root.appendingPathComponent(canonicalName, isDirectory: true) }
    public var stagingURL: URL { root.appendingPathComponent(stagingName, isDirectory: true) }
    public var priorURL: URL { root.appendingPathComponent(priorName, isDirectory: true) }
    public var journalURL: URL { root.appendingPathComponent(journalName, isDirectory: false) }

    public static func isLoaderVisible(_ name: String) -> Bool {
        !name.hasPrefix(".") && (name.hasSuffix(".iinaplugin") || name.hasSuffix(".iinaplugin-dev"))
    }

    public static func isHiddenAndLoaderInvisible(_ name: String) -> Bool {
        name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && !isLoaderVisible(name)
    }
}

public final class BundledPluginTransaction {
    private enum Kind: String, Codable { case fresh, replacement }
    private enum Phase: String, Codable { case prepared, committed }
    private struct Journal: Codable {
        let schemaVersion: Int
        let kind: Kind
        let phase: Phase
        let canonicalName: String
        let peerName: String
    }

    public let configuration: BundledPluginTransactionConfiguration
    private let fileSystem: any BundledPluginFileSystem
    private let renamer: any BundledPluginAtomicRenamer
    private let extractor: any BundledPluginArchiveExtractor
    private let validator: any BundledPluginPackageValidating
    private let checkpoint: (BundledPluginTransactionCheckpoint) throws -> Void

    public init(
        configuration: BundledPluginTransactionConfiguration,
        fileSystem: any BundledPluginFileSystem,
        renamer: any BundledPluginAtomicRenamer,
        extractor: any BundledPluginArchiveExtractor,
        validator: any BundledPluginPackageValidating,
        checkpoint: @escaping (BundledPluginTransactionCheckpoint) throws -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.fileSystem = fileSystem
        self.renamer = renamer
        self.extractor = extractor
        self.validator = validator
        self.checkpoint = checkpoint
    }

    public func installFresh(archiveData: Data) throws -> BundledPluginTransactionOutcome {
        if fileSystem.itemExists(at: configuration.journalURL) { _ = try recover() }
        if fileSystem.itemExists(at: configuration.canonicalURL) {
            if (try? validator.validateDesiredPackage(at: configuration.canonicalURL)) != nil {
                return outcome(.noChange, reload: false)
            }
            return outcome(.needsReinventory, reload: true)
        }
        try prepareStage(archiveData)
        let journal = Journal(schemaVersion: 1, kind: .fresh, phase: .prepared, canonicalName: configuration.canonicalName, peerName: configuration.stagingName)
        try writeJournal(journal)
        try checkpoint(.beforeCommit)
        guard !fileSystem.itemExists(at: configuration.canonicalURL) else {
            try cleanupTransactionFiles(includePrior: false)
            return outcome(.needsReinventory, reload: true)
        }
        do {
            try renamer.renameExclusive(from: configuration.stagingURL, to: configuration.canonicalURL)
        } catch BundledPluginAtomicRenameError.destinationExists {
            try cleanupTransactionFiles(includePrior: false)
            return outcome(.needsReinventory, reload: true)
        }
        try fileSystem.syncDirectory(at: configuration.root)
        try checkpoint(.afterCommit)
        try writeJournal(.init(schemaVersion: 1, kind: .fresh, phase: .committed, canonicalName: configuration.canonicalName, peerName: configuration.stagingName))
        try validator.validateDesiredPackage(at: configuration.canonicalURL)
        try checkpoint(.beforeCleanup)
        try cleanupTransactionFiles(includePrior: false)
        return outcome(.committedFreshInstall, reload: true)
    }

    public func replace(archiveData: Data) throws -> BundledPluginTransactionOutcome {
        if fileSystem.itemExists(at: configuration.journalURL) { _ = try recover() }
        guard fileSystem.itemExists(at: configuration.canonicalURL) else { return try installFresh(archiveData: archiveData) }
        if (try? validator.validateDesiredPackage(at: configuration.canonicalURL)) != nil { return outcome(.noChange, reload: false) }
        try prepareStage(archiveData)
        try fileSystem.removeItem(at: configuration.priorURL)
        try renamer.renameExclusive(from: configuration.stagingURL, to: configuration.priorURL)
        try fileSystem.syncDirectory(at: configuration.root)
        try writeJournal(.init(schemaVersion: 1, kind: .replacement, phase: .prepared, canonicalName: configuration.canonicalName, peerName: configuration.priorName))
        try checkpoint(.beforeCommit)
        try requireSameVolume(configuration.canonicalURL, configuration.priorURL)
        try renamer.swap(configuration.canonicalURL, configuration.priorURL)
        try fileSystem.syncDirectory(at: configuration.root)
        try checkpoint(.afterCommit)
        try writeJournal(.init(schemaVersion: 1, kind: .replacement, phase: .committed, canonicalName: configuration.canonicalName, peerName: configuration.priorName))
        try validator.validateDesiredPackage(at: configuration.canonicalURL)
        try checkpoint(.beforeCleanup)
        try cleanupTransactionFiles(includePrior: true)
        return outcome(.committedReplacement, reload: true)
    }

    public func recover() throws -> BundledPluginTransactionOutcome {
        guard fileSystem.itemExists(at: configuration.journalURL) else {
            try fileSystem.removeItem(at: configuration.stagingURL)
            try fileSystem.removeItem(at: configuration.priorURL)
            return outcome(.noChange, reload: false)
        }
        let journal: Journal
        do {
            journal = try JSONDecoder().decode(Journal.self, from: fileSystem.readData(at: configuration.journalURL))
        } catch {
            throw BundledPluginCoreError.transactionFailed("journal is unreadable")
        }
        guard journal.schemaVersion == 1,
              journal.canonicalName == configuration.canonicalName,
              journal.peerName == (journal.kind == .fresh ? configuration.stagingName : configuration.priorName) else {
            throw BundledPluginCoreError.transactionFailed("journal paths or schema are invalid")
        }
        try checkpoint(.duringRecovery)

        if validator.validateManagedPackage(at: configuration.canonicalURL) {
            try checkpoint(.beforeCleanup)
            try cleanupTransactionFiles(includePrior: true)
            return outcome(.recoveredKeepingCanonical, reload: true)
        }

        let peer = journal.kind == .fresh ? configuration.stagingURL : configuration.priorURL
        guard validator.validateManagedPackage(at: peer) else {
            throw BundledPluginCoreError.transactionFailed("neither canonical nor prior package is healthy")
        }
        if fileSystem.itemExists(at: configuration.canonicalURL) {
            try requireSameVolume(configuration.canonicalURL, peer)
            try renamer.swap(configuration.canonicalURL, peer)
        } else {
            do {
                try renamer.renameExclusive(from: peer, to: configuration.canonicalURL)
            } catch BundledPluginAtomicRenameError.destinationExists {
                return outcome(.needsReinventory, reload: true)
            }
        }
        try fileSystem.syncDirectory(at: configuration.root)
        guard validator.validateManagedPackage(at: configuration.canonicalURL) else {
            throw BundledPluginCoreError.transactionFailed("recovered canonical package did not validate")
        }
        try checkpoint(.beforeCleanup)
        try cleanupTransactionFiles(includePrior: true)
        return outcome(journal.kind == .fresh ? .recoveredFreshInstall : .recoveredPriorPackage, reload: true)
    }

    private func prepareStage(_ archiveData: Data) throws {
        try checkpoint(.beforeStaging)
        try fileSystem.removeItem(at: configuration.stagingURL)
        try fileSystem.createDirectory(at: configuration.stagingURL)
        let entries = try extractor.extract(archiveData: archiveData, to: configuration.stagingURL, fileSystem: fileSystem)
        try BundledPluginTrustedVerifier.validateArchiveEntries(entries)
        try validator.validateDesiredPackage(at: configuration.stagingURL)
        try requireSameVolume(configuration.root, configuration.stagingURL)
        try checkpoint(.afterVerification)
    }

    private func requireSameVolume(_ first: URL, _ second: URL) throws {
        guard try fileSystem.deviceIdentifier(at: first) == fileSystem.deviceIdentifier(at: second) else {
            throw BundledPluginAtomicRenameError.crossDevice
        }
    }

    private func writeJournal(_ journal: Journal) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try fileSystem.writeDataAtomicallyAndSync(encoder.encode(journal), to: configuration.journalURL)
    }

    private func cleanupTransactionFiles(includePrior: Bool) throws {
        try fileSystem.removeItem(at: configuration.stagingURL)
        if includePrior { try fileSystem.removeItem(at: configuration.priorURL) }
        try fileSystem.removeItem(at: configuration.journalURL)
        try fileSystem.syncDirectory(at: configuration.root)
    }

    private func outcome(_ status: BundledPluginTransactionStatus, reload: Bool) -> BundledPluginTransactionOutcome {
        .init(status: status, needsInventoryReload: reload, adapterState: configuration.adapterState)
    }
}

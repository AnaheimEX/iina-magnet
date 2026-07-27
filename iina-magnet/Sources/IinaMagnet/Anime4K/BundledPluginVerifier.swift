import CryptoKit
import Darwin
import Foundation

public enum BundledPluginFileKind: Sendable {
    case file
    case directory
    case symbolicLink
    case other
}

public protocol BundledPluginFileSystem {
    func itemExists(at url: URL) -> Bool
    func itemKind(at url: URL) throws -> BundledPluginFileKind
    func createDirectory(at url: URL) throws
    func removeItem(at url: URL) throws
    func readData(at url: URL) throws -> Data
    func writeDataAtomicallyAndSync(_ data: Data, to url: URL) throws
    func syncDirectory(at url: URL) throws
    func deviceIdentifier(at url: URL) throws -> UInt64
    func recursiveEntries(at root: URL) throws -> [BundledPluginArchiveEntry]
}

public struct DarwinBundledPluginFileSystem: BundledPluginFileSystem, Sendable {
    public init() {}

    public func itemExists(at url: URL) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0
    }

    public func itemKind(at url: URL) throws -> BundledPluginFileKind {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { throw posixError("lstat", url) }
        switch information.st_mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
    }

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func removeItem(at url: URL) throws {
        guard itemExists(at: url) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    public func writeDataAtomicallyAndSync(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try createDirectory(at: directory)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw posixError("open", temporary) }
        var operationError: Error?
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), rawBuffer.count - written)
                if count < 0 {
                    operationError = posixError("write", temporary)
                    return
                }
                written += count
            }
        }
        if operationError == nil, fsync(descriptor) != 0 { operationError = posixError("fsync", temporary) }
        if close(descriptor) != 0, operationError == nil { operationError = posixError("close", temporary) }
        if let operationError {
            try? FileManager.default.removeItem(at: temporary)
            throw operationError
        }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            let error = posixError("rename", url)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        try syncDirectory(at: directory)
    }

    public func syncDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError("open directory", url) }
        let result = fsync(descriptor)
        let savedErrno = errno
        _ = close(descriptor)
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(savedErrno), userInfo: [NSLocalizedDescriptionKey: "fsync directory failed: \(url.path)"])
        }
    }

    public func deviceIdentifier(at url: URL) throws -> UInt64 {
        var information = stat()
        guard stat(url.path, &information) == 0 else { throw posixError("stat", url) }
        return UInt64(information.st_dev)
    }

    public func recursiveEntries(at root: URL) throws -> [BundledPluginArchiveEntry] {
        guard try itemKind(at: root) == .directory else {
            throw BundledPluginCoreError.verificationFailed("package root is not a directory")
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else {
            throw BundledPluginCoreError.verificationFailed("cannot enumerate package tree")
        }
        let prefix = root.standardizedFileURL.path + "/"
        var entries: [BundledPluginArchiveEntry] = []
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else {
                throw BundledPluginCoreError.verificationFailed("package entry escaped root")
            }
            let relative = String(path.dropFirst(prefix.count))
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            let kind: BundledPluginArchiveEntryKind
            if values.isSymbolicLink == true {
                kind = .symbolicLink
                enumerator.skipDescendants()
            } else if values.isDirectory == true {
                kind = .directory
            } else if values.isRegularFile == true {
                kind = .file
            } else {
                kind = .other
                enumerator.skipDescendants()
            }
            let data = kind == .file ? try readData(at: url) : Data()
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
            entries.append(.init(
                path: relative,
                kind: kind,
                size: kind == .file ? (values.fileSize ?? data.count) : 0,
                sha256: kind == .file ? BundledPluginTrustedVerifier.sha256Prefixed(data) : nil,
                posixPermissions: permissions
            ))
        }
        return entries.sorted { $0.path < $1.path }
    }

    private func posixError(_ operation: String, _ url: URL) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed for \(url.path): \(String(cString: strerror(code)))"]
        )
    }
}

public struct BundledPluginVerifiedPackage: Equatable, Sendable {
    public let identifier: String
    public let version: BundledPluginSemanticVersion
    public let marker: BundledPluginManagedMarker
    public let manifestDigest: String

    public init(identifier: String, version: BundledPluginSemanticVersion, marker: BundledPluginManagedMarker, manifestDigest: String) {
        self.identifier = identifier
        self.version = version
        self.marker = marker
        self.manifestDigest = manifestDigest
    }
}

public enum BundledPluginTrustedVerifier {
    private struct InfoEnvelope: Decodable {
        let identifier: String
        let version: BundledPluginSemanticVersion
        let entry: String
        let iinaMagnetManaged: BundledPluginManagedMarker
    }

    public static func decodeCatalog(_ data: Data) throws -> BundledPluginCatalog {
        do {
            return try JSONDecoder().decode(BundledPluginCatalog.self, from: data)
        } catch {
            throw BundledPluginCoreError.invalidCatalog(error.localizedDescription)
        }
    }

    public static func decodeTrustHistory(_ data: Data) throws -> BundledPluginTrustHistory {
        do {
            return try JSONDecoder().decode(BundledPluginTrustHistory.self, from: data)
        } catch {
            throw BundledPluginCoreError.invalidCatalog("trust history: \(error.localizedDescription)")
        }
    }

    /// Validates historical metadata without requiring old archives to ship.
    /// Authenticity comes from the resource being inside the signed app; each
    /// retained catalog still binds the complete installed file tree.
    public static func verifyTrustHistory(
        _ history: BundledPluginTrustHistory,
        expected: BundledPluginTrustRequirements = .anime4K
    ) throws -> [BundledPluginCatalog] {
        guard history.schemaVersion == 1 else {
            throw BundledPluginCoreError.invalidCatalog("trust history schema mismatch")
        }
        guard history.identifier == expected.identifier else {
            throw BundledPluginCoreError.invalidCatalog("trust history identifier mismatch")
        }
        guard history.packageSchemaVersion == expected.packageSchemaVersion else {
            throw BundledPluginCoreError.invalidCatalog("trust history package schema mismatch")
        }
        guard !history.catalogs.isEmpty else {
            throw BundledPluginCoreError.invalidCatalog("trust history catalogs are missing")
        }

        var versions = Set<String>()
        for catalog in history.catalogs {
            try verifyHistoricalCatalogMetadata(catalog, expected: expected)
            guard versions.insert(catalog.version.description).inserted else {
                throw BundledPluginCoreError.invalidCatalog("duplicate historical catalog version")
            }
        }
        let sorted = history.catalogs.sorted(by: historicalCatalogOrder)
        guard history.catalogs == sorted else {
            throw BundledPluginCoreError.invalidCatalog("historical catalogs are not sorted")
        }
        return history.catalogs
    }

    @discardableResult
    public static func verifyCatalog(
        _ catalog: BundledPluginCatalog,
        archiveData: Data,
        expected: BundledPluginTrustRequirements = .anime4K
    ) throws -> BundledPluginCatalog {
        guard catalog.identifier == expected.identifier else { throw BundledPluginCoreError.invalidCatalog("identifier mismatch") }
        guard catalog.packageSchemaVersion == expected.packageSchemaVersion else { throw BundledPluginCoreError.invalidCatalog("package schema mismatch") }
        guard catalog.upstreamCommit == expected.upstreamCommit else { throw BundledPluginCoreError.invalidCatalog("upstream pin mismatch") }
        guard catalog.archive.file == expected.archiveFileName,
              catalog.archive.file == URL(fileURLWithPath: catalog.archive.file).lastPathComponent else {
            throw BundledPluginCoreError.invalidCatalog("archive filename is not trusted")
        }
        guard catalog.archive.size == archiveData.count else { throw BundledPluginCoreError.invalidCatalog("archive size mismatch") }
        try requireDigest(catalog.archive.sha256, label: "archive SHA-256")
        try requireDigest(catalog.contentManifestDigest, label: "content manifest digest")
        guard !catalog.entries.isEmpty else {
            throw BundledPluginCoreError.invalidCatalog("trusted package entries are missing")
        }
        try validateArchiveEntries(catalog.entries)
        guard catalog.entries == catalog.entries.sorted(by: { $0.path < $1.path }) else {
            throw BundledPluginCoreError.invalidCatalog("trusted package entries are not sorted")
        }
        for entry in catalog.entries {
            guard let digest = entry.sha256 else {
                throw BundledPluginCoreError.invalidCatalog("missing SHA-256 for \(entry.path)")
            }
            try requireDigest(digest, label: "entry SHA-256")
        }
        guard catalog.entries.first(where: { $0.path == "manifest.json" })?.sha256 == catalog.contentManifestDigest else {
            throw BundledPluginCoreError.invalidCatalog("manifest entry digest mismatch")
        }
        guard catalog.archive.sha256 == sha256Prefixed(archiveData) else {
            throw BundledPluginCoreError.invalidCatalog("archive SHA-256 mismatch")
        }
        return catalog
    }

    public static func validateArchiveEntries(_ entries: [BundledPluginArchiveEntry]) throws {
        guard !entries.isEmpty else { throw BundledPluginCoreError.invalidArchiveEntry("archive is empty") }
        var paths = Set<String>()
        for entry in entries {
            let path = entry.path
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty,
                  !path.hasPrefix("/"),
                  !path.contains("\\"),
                  !path.contains("\0"),
                  !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw BundledPluginCoreError.invalidArchiveEntry("non-normalized path \(path)")
            }
            guard paths.insert(path).inserted else { throw BundledPluginCoreError.invalidArchiveEntry("duplicate path \(path)") }
            guard entry.kind == .file else { throw BundledPluginCoreError.invalidArchiveEntry("non-regular entry \(path)") }
            guard entry.size >= 0 else { throw BundledPluginCoreError.invalidArchiveEntry("negative size \(path)") }
            guard entry.posixPermissions & 0o111 == 0 else { throw BundledPluginCoreError.invalidArchiveEntry("executable entry \(path)") }
            if let digest = entry.sha256 { try requireDigest(digest, label: "entry SHA-256") }
        }
        for required in ["Info.json", "manifest.json", "main.js"] where !paths.contains(required) {
            throw BundledPluginCoreError.invalidArchiveEntry("missing \(required)")
        }
    }

    public static func verifyExtractedPackage(
        at root: URL,
        catalog: BundledPluginCatalog,
        fileSystem: any BundledPluginFileSystem,
        expected: BundledPluginTrustRequirements = .anime4K
    ) throws -> BundledPluginVerifiedPackage {
        try verifyInstalledTree(at: root, expectedEntries: catalog.entries, fileSystem: fileSystem)
        let verified = try verifyManagedPackage(at: root, fileSystem: fileSystem, expected: expected)
        guard verified.identifier == catalog.identifier,
              verified.version == catalog.version,
              verified.marker == BundledPluginManagedMarker(
                  contentManifestDigest: catalog.contentManifestDigest,
                  owner: expected.owner,
                  packageSchemaVersion: catalog.packageSchemaVersion,
                  version: catalog.version
              ) else {
            throw BundledPluginCoreError.verificationFailed("catalog and Info.json marker mismatch")
        }
        return verified
    }

    public static func verifyInstalledPackage(
        at root: URL,
        catalog: BundledPluginCatalog,
        fileSystem: any BundledPluginFileSystem,
        expected: BundledPluginTrustRequirements = .anime4K
    ) throws -> BundledPluginVerifiedPackage {
        try verifyExtractedPackage(at: root, catalog: catalog, fileSystem: fileSystem, expected: expected)
    }

    public static func verifyManagedPackage(
        at root: URL,
        fileSystem: any BundledPluginFileSystem,
        expected: BundledPluginTrustRequirements = .anime4K
    ) throws -> BundledPluginVerifiedPackage {
        guard try fileSystem.itemKind(at: root) == .directory else {
            throw BundledPluginCoreError.verificationFailed("package root is not a directory")
        }
        let infoURL = root.appendingPathComponent("Info.json")
        let manifestURL = root.appendingPathComponent("manifest.json")
        let mainURL = root.appendingPathComponent("main.js")
        for url in [infoURL, manifestURL, mainURL] {
            guard fileSystem.itemExists(at: url), try fileSystem.itemKind(at: url) == .file else {
                throw BundledPluginCoreError.verificationFailed("missing regular file \(url.lastPathComponent)")
            }
        }
        let info: InfoEnvelope
        do {
            info = try JSONDecoder().decode(InfoEnvelope.self, from: fileSystem.readData(at: infoURL))
        } catch {
            throw BundledPluginCoreError.invalidManagedMarker(error.localizedDescription)
        }
        let marker = info.iinaMagnetManaged
        guard info.identifier == expected.identifier,
              info.entry == "main.js",
              marker.owner == expected.owner,
              marker.packageSchemaVersion == expected.packageSchemaVersion,
              marker.version == info.version else {
            throw BundledPluginCoreError.invalidManagedMarker("identity, owner, schema, entry, or version mismatch")
        }
        try requireDigest(marker.contentManifestDigest, label: "managed content manifest digest")
        let digest = sha256Prefixed(try fileSystem.readData(at: manifestURL))
        guard digest == marker.contentManifestDigest else {
            throw BundledPluginCoreError.verificationFailed("manifest digest mismatch")
        }
        return .init(identifier: info.identifier, version: info.version, marker: marker, manifestDigest: digest)
    }

    public static func sha256Prefixed(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func verifyHistoricalCatalogMetadata(
        _ catalog: BundledPluginCatalog,
        expected: BundledPluginTrustRequirements
    ) throws {
        guard catalog.identifier == expected.identifier else {
            throw BundledPluginCoreError.invalidCatalog("historical identifier mismatch")
        }
        guard catalog.packageSchemaVersion == expected.packageSchemaVersion else {
            throw BundledPluginCoreError.invalidCatalog("historical package schema mismatch")
        }
        guard catalog.archive.file == expected.archiveFileName,
              catalog.archive.file == URL(fileURLWithPath: catalog.archive.file).lastPathComponent else {
            throw BundledPluginCoreError.invalidCatalog("historical archive filename is not trusted")
        }
        guard catalog.archive.size > 0 else {
            throw BundledPluginCoreError.invalidCatalog("historical archive size is invalid")
        }
        try requireDigest(catalog.archive.sha256, label: "historical archive SHA-256")
        try requireDigest(catalog.contentManifestDigest, label: "historical content manifest digest")
        try requireHex(catalog.upstreamCommit, count: 40, label: "historical upstream commit")
        guard !catalog.entries.isEmpty else {
            throw BundledPluginCoreError.invalidCatalog("historical package entries are missing")
        }
        try validateArchiveEntries(catalog.entries)
        guard catalog.entries == catalog.entries.sorted(by: { $0.path < $1.path }) else {
            throw BundledPluginCoreError.invalidCatalog("historical package entries are not sorted")
        }
        for entry in catalog.entries {
            guard let digest = entry.sha256 else {
                throw BundledPluginCoreError.invalidCatalog("missing historical SHA-256 for \(entry.path)")
            }
            guard entry.posixPermissions == 0o644 else {
                throw BundledPluginCoreError.invalidCatalog("historical entry permissions are not canonical")
            }
            try requireDigest(digest, label: "historical entry SHA-256")
        }
        guard catalog.entries.first(where: { $0.path == "manifest.json" })?.sha256 == catalog.contentManifestDigest else {
            throw BundledPluginCoreError.invalidCatalog("historical manifest entry digest mismatch")
        }
    }

    private static func historicalCatalogOrder(
        _ left: BundledPluginCatalog,
        _ right: BundledPluginCatalog
    ) -> Bool {
        let leftKey = (left.version.description, left.archive.sha256)
        let rightKey = (right.version.description, right.archive.sha256)
        return leftKey < rightKey
    }

    private static func verifyInstalledTree(
        at root: URL,
        expectedEntries: [BundledPluginArchiveEntry],
        fileSystem: any BundledPluginFileSystem
    ) throws {
        guard !expectedEntries.isEmpty else {
            throw BundledPluginCoreError.verificationFailed("trusted package entries are missing")
        }
        try validateArchiveEntries(expectedEntries)
        let actualTree = try fileSystem.recursiveEntries(at: root)
        let actualFiles = actualTree.filter { $0.kind == .file }
        guard actualTree.allSatisfy({ $0.kind == .file || $0.kind == .directory }) else {
            throw BundledPluginCoreError.verificationFailed("package contains a symlink or special entry")
        }
        let expectedDirectories = directoryPaths(for: expectedEntries.map(\.path))
        let actualDirectories = Set(actualTree.lazy.filter { $0.kind == .directory }.map(\.path))
        guard actualDirectories == expectedDirectories else {
            throw BundledPluginCoreError.verificationFailed("package directory allow-list mismatch")
        }
        guard actualFiles == expectedEntries else {
            throw BundledPluginCoreError.verificationFailed("package file allow-list, size, digest, or permissions mismatch")
        }
    }

    private static func directoryPaths(for filePaths: [String]) -> Set<String> {
        var directories = Set<String>()
        for path in filePaths {
            let components = path.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            for count in 1..<components.count {
                directories.insert(components.prefix(count).joined(separator: "/"))
            }
        }
        return directories
    }

    private static func requireDigest(_ digest: String, label: String) throws {
        let value = digest.hasPrefix("sha256:") ? String(digest.dropFirst(7)) : ""
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
              }) else {
            throw BundledPluginCoreError.invalidCatalog("\(label) is not canonical lowercase SHA-256")
        }
    }

    private static func requireHex(_ value: String, count: Int, label: String) throws {
        guard value.count == count,
              value.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
              }) else {
            throw BundledPluginCoreError.invalidCatalog("\(label) is not canonical lowercase hexadecimal")
        }
    }
}

public protocol BundledPluginPackageValidating {
    func validateDesiredPackage(at url: URL) throws
    func validateManagedPackage(at url: URL) -> Bool
}

/// Production validator separating the desired package from the signed-app
/// trust set used for canonical/prior recovery.
public struct BundledPluginCatalogSetPackageValidator: BundledPluginPackageValidating {
    public let desiredCatalog: BundledPluginCatalog
    public let trustedManagedCatalogs: [BundledPluginCatalog]
    public let fileSystem: any BundledPluginFileSystem
    public let expected: BundledPluginTrustRequirements

    public init(
        desiredCatalog: BundledPluginCatalog,
        trustedManagedCatalogs: [BundledPluginCatalog],
        fileSystem: any BundledPluginFileSystem,
        expected: BundledPluginTrustRequirements = .anime4K
    ) {
        self.desiredCatalog = desiredCatalog
        self.trustedManagedCatalogs = trustedManagedCatalogs
        self.fileSystem = fileSystem
        self.expected = expected
    }

    public func validateDesiredPackage(at url: URL) throws {
        _ = try BundledPluginTrustedVerifier.verifyInstalledPackage(
            at: url,
            catalog: desiredCatalog,
            fileSystem: fileSystem,
            expected: expected
        )
    }

    public func validateManagedPackage(at url: URL) -> Bool {
        (trustedManagedCatalogs + [desiredCatalog]).contains { catalog in
            (try? BundledPluginTrustedVerifier.verifyInstalledPackage(
                at: url,
                catalog: catalog,
                fileSystem: fileSystem,
                expected: expected
            )) != nil
        }
    }
}

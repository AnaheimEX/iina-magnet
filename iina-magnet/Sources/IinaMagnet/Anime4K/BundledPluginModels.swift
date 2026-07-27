import Foundation

public enum BundledPluginCoreError: Error, Equatable, LocalizedError {
    case invalidSemanticVersion(String)
    case invalidCatalog(String)
    case invalidManagedMarker(String)
    case invalidArchiveEntry(String)
    case invalidLocalPath(String)
    case invalidTransactionConfiguration(String)
    case verificationFailed(String)
    case extractionFailed(String)
    case transactionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSemanticVersion(let value): "Invalid semantic version: \(value)"
        case .invalidCatalog(let reason): "Invalid bundled plugin catalog: \(reason)"
        case .invalidManagedMarker(let reason): "Invalid managed plugin marker: \(reason)"
        case .invalidArchiveEntry(let reason): "Invalid bundled plugin archive entry: \(reason)"
        case .invalidLocalPath(let path): "Invalid plugin-local path: \(path)"
        case .invalidTransactionConfiguration(let reason): "Invalid bundled plugin transaction configuration: \(reason)"
        case .verificationFailed(let reason): "Bundled plugin verification failed: \(reason)"
        case .extractionFailed(let reason): "Bundled plugin extraction failed: \(reason)"
        case .transactionFailed(let reason): "Bundled plugin transaction failed: \(reason)"
        }
    }
}

public struct BundledPluginSemanticVersion: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let major: UInt64
    public let minor: UInt64
    public let patch: UInt64
    public let prerelease: [String]
    public let buildMetadata: [String]

    public init(
        major: UInt64,
        minor: UInt64,
        patch: UInt64,
        prerelease: [String] = [],
        buildMetadata: [String] = []
    ) throws {
        try Self.validateIdentifiers(prerelease, numericLeadingZeroForbidden: true)
        try Self.validateIdentifiers(buildMetadata, numericLeadingZeroForbidden: false)
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.buildMetadata = buildMetadata
    }

    public init(parsing value: String) throws {
        let buildSplit = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard buildSplit.count <= 2, !buildSplit[0].isEmpty else {
            throw BundledPluginCoreError.invalidSemanticVersion(value)
        }
        let build = buildSplit.count == 2 ? String(buildSplit[1]) : nil
        let prereleaseSplit = buildSplit[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard prereleaseSplit.count <= 2, !prereleaseSplit[0].isEmpty else {
            throw BundledPluginCoreError.invalidSemanticVersion(value)
        }
        let core = prereleaseSplit[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Self.parseCoreNumber(core[0]),
              let minor = Self.parseCoreNumber(core[1]),
              let patch = Self.parseCoreNumber(core[2]) else {
            throw BundledPluginCoreError.invalidSemanticVersion(value)
        }
        let prerelease = prereleaseSplit.count == 2 ? String(prereleaseSplit[1]).split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        let buildMetadata = build.map { $0.split(separator: ".", omittingEmptySubsequences: false).map(String.init) } ?? []
        do {
            try self.init(major: major, minor: minor, patch: patch, prerelease: prerelease, buildMetadata: buildMetadata)
        } catch {
            throw BundledPluginCoreError.invalidSemanticVersion(value)
        }
    }

    public var description: String {
        var value = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty { value += "-" + prerelease.joined(separator: ".") }
        if !buildMetadata.isEmpty { value += "+" + buildMetadata.joined(separator: ".") }
        return value
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for index in 0..<min(lhs.prerelease.count, rhs.prerelease.count) {
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right { continue }
            let leftNumber = UInt64(left)
            let rightNumber = UInt64(right)
            switch (leftNumber, rightNumber) {
            case (.some(let left), .some(let right)): return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(parsing: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private static func parseCoreNumber(_ value: Substring) -> UInt64? {
        guard !value.isEmpty, value.allSatisfy(\.isNumber), value == "0" || value.first != "0" else { return nil }
        return UInt64(value)
    }

    private static func validateIdentifiers(_ values: [String], numericLeadingZeroForbidden: Bool) throws {
        for value in values {
            guard !value.isEmpty,
                  value.unicodeScalars.allSatisfy({ scalar in
                      scalar.value == 45 ||
                      (48...57).contains(scalar.value) ||
                      (65...90).contains(scalar.value) ||
                      (97...122).contains(scalar.value)
                  }) else {
                throw BundledPluginCoreError.invalidSemanticVersion(value)
            }
            if numericLeadingZeroForbidden, value.allSatisfy(\.isNumber), value.count > 1, value.first == "0" {
                throw BundledPluginCoreError.invalidSemanticVersion(value)
            }
        }
    }
}

public struct BundledPluginCatalog: Codable, Equatable, Sendable {
    public struct Archive: Codable, Equatable, Sendable {
        public let file: String
        public let sha256: String
        public let size: Int

        public init(file: String, sha256: String, size: Int) {
            self.file = file
            self.sha256 = sha256
            self.size = size
        }
    }

    public let archive: Archive
    public let contentManifestDigest: String
    /// Trusted allow-list for every regular file in the extracted package.
    ///
    /// Decoding accepts an absent field so an older catalog can be diagnosed,
    /// but production verification rejects an empty list. This prevents a
    /// matching Info.json/manifest.json pair from hiding modified code, UI, or
    /// unexpected filesystem entries.
    public let entries: [BundledPluginArchiveEntry]
    public let identifier: String
    public let packageSchemaVersion: Int
    public let upstreamCommit: String
    public let version: BundledPluginSemanticVersion

    public init(
        archive: Archive,
        contentManifestDigest: String,
        entries: [BundledPluginArchiveEntry] = [],
        identifier: String,
        packageSchemaVersion: Int,
        upstreamCommit: String,
        version: BundledPluginSemanticVersion
    ) {
        self.archive = archive
        self.contentManifestDigest = contentManifestDigest
        self.entries = entries
        self.identifier = identifier
        self.packageSchemaVersion = packageSchemaVersion
        self.upstreamCommit = upstreamCommit
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case archive
        case contentManifestDigest
        case entries
        case identifier
        case packageSchemaVersion
        case upstreamCommit
        case version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        archive = try container.decode(Archive.self, forKey: .archive)
        contentManifestDigest = try container.decode(String.self, forKey: .contentManifestDigest)
        entries = try container.decodeIfPresent([BundledPluginArchiveEntry].self, forKey: .entries) ?? []
        identifier = try container.decode(String.self, forKey: .identifier)
        packageSchemaVersion = try container.decode(Int.self, forKey: .packageSchemaVersion)
        upstreamCommit = try container.decode(String.self, forKey: .upstreamCommit)
        version = try container.decode(BundledPluginSemanticVersion.self, forKey: .version)
    }
}

/// Signed-app-bundled full-tree catalogs accepted for managed rollback and
/// restart recovery. No copy from the user-writable plugin directory is ever
/// decoded as trust metadata.
public struct BundledPluginTrustHistory: Codable, Equatable, Sendable {
    public let catalogs: [BundledPluginCatalog]
    public let identifier: String
    public let packageSchemaVersion: Int
    public let schemaVersion: Int

    public init(
        catalogs: [BundledPluginCatalog],
        identifier: String,
        packageSchemaVersion: Int,
        schemaVersion: Int
    ) {
        self.catalogs = catalogs
        self.identifier = identifier
        self.packageSchemaVersion = packageSchemaVersion
        self.schemaVersion = schemaVersion
    }
}

public struct BundledPluginManagedMarker: Codable, Equatable, Sendable {
    public let contentManifestDigest: String
    public let owner: String
    public let packageSchemaVersion: Int
    public let version: BundledPluginSemanticVersion

    public init(contentManifestDigest: String, owner: String, packageSchemaVersion: Int, version: BundledPluginSemanticVersion) {
        self.contentManifestDigest = contentManifestDigest
        self.owner = owner
        self.packageSchemaVersion = packageSchemaVersion
        self.version = version
    }
}

public enum BundledPluginArchiveEntryKind: String, Codable, Sendable {
    case file
    case directory
    case symbolicLink
    case other
}

public struct BundledPluginArchiveEntry: Codable, Equatable, Sendable {
    public let path: String
    public let kind: BundledPluginArchiveEntryKind
    public let size: Int
    public let sha256: String?
    public let posixPermissions: UInt16

    public init(path: String, kind: BundledPluginArchiveEntryKind = .file, size: Int, sha256: String? = nil, posixPermissions: UInt16 = 0o644) {
        self.path = path
        self.kind = kind
        self.size = size
        self.sha256 = sha256
        self.posixPermissions = posixPermissions
    }
}

public struct BundledPluginPackageSnapshot: Equatable, Sendable {
    public let directoryName: String
    public let identifier: String
    public let marker: BundledPluginManagedMarker?
    public let isHealthy: Bool

    public init(directoryName: String, identifier: String, marker: BundledPluginManagedMarker?, isHealthy: Bool) {
        self.directoryName = directoryName
        self.identifier = identifier
        self.marker = marker
        self.isHealthy = isHealthy
    }
}

public struct BundledPluginInventory: Equatable, Sendable {
    public let forkPackages: [BundledPluginPackageSnapshot]
    public let communityPackages: [BundledPluginPackageSnapshot]
    public let storedEnabled: Bool?
    public let storedOrder: [String]

    public init(
        forkPackages: [BundledPluginPackageSnapshot] = [],
        communityPackages: [BundledPluginPackageSnapshot] = [],
        storedEnabled: Bool? = nil,
        storedOrder: [String] = []
    ) {
        self.forkPackages = forkPackages
        self.communityPackages = communityPackages
        self.storedEnabled = storedEnabled
        self.storedOrder = storedOrder
    }
}

public enum BundledPluginInstalledState: String, Codable, Sendable {
    case absent
    case managedHealthySameVersion
    case managedOlder
    case managedNewer
    case managedCorrupt
    case unmanagedSameIdentifier
    case communityConflict
    case multipleOwners
}

public enum BundledPluginAction: String, Codable, Sendable {
    case noOp
    case install
    case upgrade
    case repair
    case requireUnmanagedReplacement
    case requireCommunityMigration
    case resolveMultipleOwners
}

public enum BundledPluginPendingResolution: String, Codable, Sendable {
    case unmanagedReplacement
    case communityMigration
    case multipleOwners
}

public struct BundledPluginDecision: Equatable, Sendable {
    public let state: BundledPluginInstalledState
    public let action: BundledPluginAction
    public let disableIdentifiers: [String]
    public let pendingResolution: BundledPluginPendingResolution?
    public let shouldEnableFreshShell: Bool
    public let preserveEnabledState: Bool
    public let preservedOrder: [String]

    public init(
        state: BundledPluginInstalledState,
        action: BundledPluginAction,
        disableIdentifiers: [String] = [],
        pendingResolution: BundledPluginPendingResolution? = nil,
        shouldEnableFreshShell: Bool = false,
        preserveEnabledState: Bool = true,
        preservedOrder: [String]
    ) {
        self.state = state
        self.action = action
        self.disableIdentifiers = disableIdentifiers
        self.pendingResolution = pendingResolution
        self.shouldEnableFreshShell = shouldEnableFreshShell
        self.preserveEnabledState = preserveEnabledState
        self.preservedOrder = preservedOrder
    }
}

public struct BundledPluginTrustRequirements: Equatable, Sendable {
    public let identifier: String
    public let owner: String
    public let packageSchemaVersion: Int
    public let upstreamCommit: String
    public let archiveFileName: String

    public init(identifier: String, owner: String, packageSchemaVersion: Int, upstreamCommit: String, archiveFileName: String) {
        self.identifier = identifier
        self.owner = owner
        self.packageSchemaVersion = packageSchemaVersion
        self.upstreamCommit = upstreamCommit
        self.archiveFileName = archiveFileName
    }

    public static let anime4K = Self(
        identifier: "io.iina.magnet.anime4k",
        owner: "iina-magnet",
        packageSchemaVersion: 1,
        upstreamCommit: "7684e9586f8dcc738af08a1cdceb024cc184f426",
        archiveFileName: "anime4k.iinaplgz"
    )
}

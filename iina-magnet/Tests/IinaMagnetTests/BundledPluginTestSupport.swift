import Foundation
@testable import IinaMagnet

struct BundledPluginTestPackageFixture {
    let version: BundledPluginSemanticVersion
    let archiveData: Data
    let files: [String: Data]
    let catalog: BundledPluginCatalog

    static func make(
        version value: String = "1.0.0",
        main: String = "fixture-main-v1",
        runtime: String = "fixture-runtime-v1"
    ) throws -> Self {
        let version = try BundledPluginSemanticVersion(parsing: value)
        let manifest = Data(#"{"fixture":"anime4k","schema":1}"#.utf8)
        let manifestDigest = BundledPluginTrustedVerifier.sha256Prefixed(manifest)
        let infoObject: [String: Any] = [
            "entry": "main.js",
            "identifier": BundledPluginTrustRequirements.anime4K.identifier,
            "iinaMagnetManaged": [
                "contentManifestDigest": manifestDigest,
                "owner": BundledPluginTrustRequirements.anime4K.owner,
                "packageSchemaVersion": BundledPluginTrustRequirements.anime4K.packageSchemaVersion,
                "version": version.description,
            ],
            "version": version.description,
        ]
        let info = try JSONSerialization.data(withJSONObject: infoObject, options: [.sortedKeys])
        let files: [String: Data] = [
            "Info.json": info,
            "lib/runtime.js": Data(runtime.utf8),
            "main.js": Data(main.utf8),
            "manifest.json": manifest,
            "ui/sidebar.html": Data("<p>fixture</p>".utf8),
        ]
        let entries = files.map { path, data in
            BundledPluginArchiveEntry(
                path: path,
                size: data.count,
                sha256: BundledPluginTrustedVerifier.sha256Prefixed(data),
                posixPermissions: 0o644
            )
        }.sorted { $0.path < $1.path }
        let archiveData = Data("archive-\(value)-\(main)-\(runtime)".utf8)
        let catalog = BundledPluginCatalog(
            archive: .init(
                file: BundledPluginTrustRequirements.anime4K.archiveFileName,
                sha256: BundledPluginTrustedVerifier.sha256Prefixed(archiveData),
                size: archiveData.count
            ),
            contentManifestDigest: manifestDigest,
            entries: entries,
            identifier: BundledPluginTrustRequirements.anime4K.identifier,
            packageSchemaVersion: BundledPluginTrustRequirements.anime4K.packageSchemaVersion,
            upstreamCommit: BundledPluginTrustRequirements.anime4K.upstreamCommit,
            version: version
        )
        return .init(version: version, archiveData: archiveData, files: files, catalog: catalog)
    }

    func write(to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
    }
}

struct BundledPluginFixtureExtractor: BundledPluginArchiveExtractor {
    let fixture: BundledPluginTestPackageFixture

    func extract(
        archiveData: Data,
        to destination: URL,
        fileSystem: any BundledPluginFileSystem
    ) throws -> [BundledPluginArchiveEntry] {
        guard archiveData == fixture.archiveData else {
            throw BundledPluginCoreError.extractionFailed("unexpected fixture archive")
        }
        try fixture.write(to: destination)
        return fixture.catalog.entries
    }
}

final class BundledPluginRecordingRenamer: BundledPluginAtomicRenamer {
    enum Call: Equatable { case exclusive, swap }

    private(set) var calls: [Call] = []
    private let base = DarwinBundledPluginAtomicRenamer()

    func renameExclusive(from source: URL, to destination: URL) throws {
        calls.append(.exclusive)
        try base.renameExclusive(from: source, to: destination)
    }

    func swap(_ first: URL, _ second: URL) throws {
        calls.append(.swap)
        try base.swap(first, second)
    }
}

func makeBundledPluginTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("iina-magnet-bundled-plugin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func bundledPluginLoaderVisibleNames(at root: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: root.path)
        .filter(BundledPluginTransactionConfiguration.isLoaderVisible)
        .sorted()
}

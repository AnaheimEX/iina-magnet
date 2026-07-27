import Foundation
import Testing
@testable import IinaMagnet

@Suite struct BundledPluginVerifierTests {
    private let fileSystem = DarwinBundledPluginFileSystem()

    @Test func committedAnime4KArchiveCatalogAndDittoExtractionVerifyEndToEnd() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let archiveData = try Data(contentsOf: repositoryRoot.appendingPathComponent("deps/plugins/anime4k.iinaplgz"))
        let catalogData = try Data(contentsOf: repositoryRoot.appendingPathComponent("deps/plugins/anime4k.catalog.json"))
        let catalog = try BundledPluginTrustedVerifier.decodeCatalog(catalogData)
        _ = try BundledPluginTrustedVerifier.verifyCatalog(catalog, archiveData: archiveData)

        let root = try makeBundledPluginTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("anime4k.iinaplugin")
        try fileSystem.createDirectory(at: package)
        let extracted = try DittoBundledPluginArchiveExtractor().extract(
            archiveData: archiveData,
            to: package,
            fileSystem: fileSystem
        )
        try BundledPluginTrustedVerifier.validateArchiveEntries(extracted)
        #expect(extracted == catalog.entries)
        _ = try BundledPluginTrustedVerifier.verifyInstalledPackage(
            at: package,
            catalog: catalog,
            fileSystem: fileSystem
        )
    }

    @Test func trustedCatalogAndCompleteInstalledTreeVerify() throws {
        let fixture = try BundledPluginTestPackageFixture.make()
        let root = try makeBundledPluginTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("anime4k.iinaplugin")
        try fixture.write(to: package)

        let decoded = try BundledPluginTrustedVerifier.decodeCatalog(
            JSONEncoder().encode(fixture.catalog)
        )
        let verifiedCatalog = try BundledPluginTrustedVerifier.verifyCatalog(
            decoded,
            archiveData: fixture.archiveData
        )
        let verifiedPackage = try BundledPluginTrustedVerifier.verifyInstalledPackage(
            at: package,
            catalog: verifiedCatalog,
            fileSystem: fileSystem
        )

        #expect(verifiedPackage.identifier == fixture.catalog.identifier)
        #expect(verifiedPackage.version == fixture.version)
        #expect(verifiedPackage.manifestDigest == fixture.catalog.contentManifestDigest)
    }

    @Test func productionCatalogSetUsesCurrentForDesiredAndHistoryForManagedPackages() throws {
        let old = try BundledPluginTestPackageFixture.make(version: "1.0.0", main: "old")
        let current = try BundledPluginTestPackageFixture.make(version: "2.0.0", main: "current")
        let root = try makeBundledPluginTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldPackage = root.appendingPathComponent("old.iinaplugin")
        let currentPackage = root.appendingPathComponent("current.iinaplugin")
        try old.write(to: oldPackage)
        try current.write(to: currentPackage)
        let validator = BundledPluginCatalogSetPackageValidator(
            desiredCatalog: current.catalog,
            trustedManagedCatalogs: [old.catalog, current.catalog],
            fileSystem: fileSystem
        )

        #expect(validator.validateManagedPackage(at: oldPackage))
        #expect(validator.validateManagedPackage(at: currentPackage))
        do {
            try validator.validateDesiredPackage(at: oldPackage)
            Issue.record("historical package was accepted as desired staging")
        } catch is BundledPluginCoreError {
            // Expected: staging is bound only to the current catalog.
        }
        try validator.validateDesiredPackage(at: currentPackage)
    }

    @Test func bundledTrustHistoryRequiresCanonicalFullTreeCatalogMetadata() throws {
        let first = try BundledPluginTestPackageFixture.make(version: "1.0.0", main: "first")
        let second = try BundledPluginTestPackageFixture.make(version: "2.0.0", main: "second")
        let history = BundledPluginTrustHistory(
            catalogs: [first.catalog, second.catalog],
            identifier: BundledPluginTrustRequirements.anime4K.identifier,
            packageSchemaVersion: BundledPluginTrustRequirements.anime4K.packageSchemaVersion,
            schemaVersion: 1
        )
        let decoded = try BundledPluginTrustedVerifier.decodeTrustHistory(JSONEncoder().encode(history))
        let catalogs = try BundledPluginTrustedVerifier.verifyTrustHistory(decoded)
        #expect(catalogs == [first.catalog, second.catalog])

        let invalidHistory = BundledPluginTrustHistory(
            catalogs: [replacing(first.catalog, entries: [])],
            identifier: history.identifier,
            packageSchemaVersion: history.packageSchemaVersion,
            schemaVersion: history.schemaVersion
        )
        expectCoreError {
            _ = try BundledPluginTrustedVerifier.verifyTrustHistory(invalidHistory)
        }

        let badDigest = BundledPluginCatalog.Archive(
            file: first.catalog.archive.file,
            sha256: "sha256:INVALID",
            size: first.catalog.archive.size
        )
        let invalidCatalogs = [
            replacing(first.catalog, archive: badDigest),
            replacing(first.catalog, upstreamCommit: "NOT-A-COMMIT"),
        ]
        for catalog in invalidCatalogs {
            expectCoreError {
                _ = try BundledPluginTrustedVerifier.verifyTrustHistory(.init(
                    catalogs: [catalog],
                    identifier: history.identifier,
                    packageSchemaVersion: history.packageSchemaVersion,
                    schemaVersion: history.schemaVersion
                ))
            }
        }
        expectCoreError {
            _ = try BundledPluginTrustedVerifier.verifyTrustHistory(.init(
                catalogs: [second.catalog, first.catalog],
                identifier: history.identifier,
                packageSchemaVersion: history.packageSchemaVersion,
                schemaVersion: history.schemaVersion
            ))
        }
        expectCoreError {
            _ = try BundledPluginTrustedVerifier.verifyTrustHistory(.init(
                catalogs: [first.catalog, first.catalog],
                identifier: history.identifier,
                packageSchemaVersion: history.packageSchemaVersion,
                schemaVersion: history.schemaVersion
            ))
        }
    }

    @Test func productionCatalogRequiresSortedCompleteFileDigests() throws {
        let fixture = try BundledPluginTestPackageFixture.make()
        expectCoreError {
            _ = try BundledPluginTrustedVerifier.verifyCatalog(
                replacing(fixture.catalog, entries: []),
                archiveData: fixture.archiveData
            )
        }
        expectCoreError {
            _ = try BundledPluginTrustedVerifier.verifyCatalog(
                replacing(fixture.catalog, entries: fixture.catalog.entries.reversed()),
                archiveData: fixture.archiveData
            )
        }
        var entries = fixture.catalog.entries
        let mainIndex = try #require(entries.firstIndex { $0.path == "main.js" })
        entries[mainIndex] = .init(path: "main.js", size: entries[mainIndex].size, sha256: nil)
        expectCoreError {
            _ = try BundledPluginTrustedVerifier.verifyCatalog(
                replacing(fixture.catalog, entries: entries),
                archiveData: fixture.archiveData
            )
        }
    }

    @Test func catalogRejectsArchiveIdentityPinSchemaHashAndSizeDrift() throws {
        let fixture = try BundledPluginTestPackageFixture.make()
        let badArchive = BundledPluginCatalog.Archive(
            file: fixture.catalog.archive.file,
            sha256: "sha256:" + String(repeating: "0", count: 64),
            size: fixture.catalog.archive.size
        )
        let cases = [
            replacing(fixture.catalog, archive: badArchive),
            replacing(fixture.catalog, archive: .init(
                file: fixture.catalog.archive.file,
                sha256: fixture.catalog.archive.sha256,
                size: fixture.catalog.archive.size + 1
            )),
            replacing(fixture.catalog, identifier: "other.identifier"),
            replacing(fixture.catalog, packageSchemaVersion: 2),
            replacing(fixture.catalog, upstreamCommit: String(repeating: "0", count: 40)),
        ]
        for catalog in cases {
            expectCoreError {
                _ = try BundledPluginTrustedVerifier.verifyCatalog(
                    catalog,
                    archiveData: fixture.archiveData
                )
            }
        }
    }

    @Test func malformedCatalogJSONAndSemanticVersionAreRejected() throws {
        expectCoreError {
            _ = try BundledPluginTrustedVerifier.decodeCatalog(Data("not-json".utf8))
        }
        let fixture = try BundledPluginTestPackageFixture.make()
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.catalog)) as? [String: Any]
        )
        object["version"] = "1.0.0-01"
        expectCoreError {
            _ = try BundledPluginTrustedVerifier.decodeCatalog(
                JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test func tamperedMainAndNestedLibraryAreRejected() throws {
        let fixture = try BundledPluginTestPackageFixture.make()
        for path in ["main.js", "lib/runtime.js"] {
            let root = try makeBundledPluginTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let package = root.appendingPathComponent("anime4k.iinaplugin")
            try fixture.write(to: package)
            try Data("tampered".utf8).write(to: package.appendingPathComponent(path))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: package.appendingPathComponent(path).path
            )

            expectCoreError {
                _ = try BundledPluginTrustedVerifier.verifyInstalledPackage(
                    at: package,
                    catalog: fixture.catalog,
                    fileSystem: fileSystem
                )
            }
        }
    }

    @Test func extraFilesDirectoriesSymlinksAndExecutableBitsAreRejected() throws {
        let fixture = try BundledPluginTestPackageFixture.make()
        let mutations: [(URL) throws -> Void] = [
            { package in
                try Data("extra".utf8).write(to: package.appendingPathComponent("extra.js"))
            },
            { package in
                try FileManager.default.createDirectory(
                    at: package.appendingPathComponent("unexpected-empty"),
                    withIntermediateDirectories: false
                )
            },
            { package in
                try FileManager.default.createSymbolicLink(
                    atPath: package.appendingPathComponent("linked-main.js").path,
                    withDestinationPath: "main.js"
                )
            },
            { package in
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: package.appendingPathComponent("main.js").path
                )
            },
        ]
        for mutation in mutations {
            let root = try makeBundledPluginTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let package = root.appendingPathComponent("anime4k.iinaplugin")
            try fixture.write(to: package)
            try mutation(package)
            expectCoreError {
                _ = try BundledPluginTrustedVerifier.verifyInstalledPackage(
                    at: package,
                    catalog: fixture.catalog,
                    fileSystem: fileSystem
                )
            }
        }
    }

    @Test func markerManifestAndRequiredFileDriftAreRejected() throws {
        let fixture = try BundledPluginTestPackageFixture.make()
        for path in ["Info.json", "manifest.json", "main.js"] {
            let root = try makeBundledPluginTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let package = root.appendingPathComponent("anime4k.iinaplugin")
            try fixture.write(to: package)
            try FileManager.default.removeItem(at: package.appendingPathComponent(path))
            expectCoreError {
                _ = try BundledPluginTrustedVerifier.verifyManagedPackage(
                    at: package,
                    fileSystem: fileSystem
                )
            }
        }

        let root = try makeBundledPluginTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("anime4k.iinaplugin")
        try fixture.write(to: package)
        try Data(#"{"changed":true}"#.utf8).write(
            to: package.appendingPathComponent("manifest.json")
        )
        expectCoreError {
            _ = try BundledPluginTrustedVerifier.verifyManagedPackage(
                at: package,
                fileSystem: fileSystem
            )
        }
    }

    @Test func markerIdentityOwnerSchemaEntryAndVersionDriftAreRejected() throws {
        let fixture = try BundledPluginTestPackageFixture.make()
        let mutations: [([String: Any]) -> [String: Any]] = [
            { info in
                var changed = info
                changed["identifier"] = "other.identifier"
                return changed
            },
            { info in
                var changed = info
                changed["entry"] = "other.js"
                return changed
            },
            { info in
                var changed = info
                var marker = changed["iinaMagnetManaged"] as! [String: Any]
                marker["owner"] = "other-owner"
                changed["iinaMagnetManaged"] = marker
                return changed
            },
            { info in
                var changed = info
                var marker = changed["iinaMagnetManaged"] as! [String: Any]
                marker["packageSchemaVersion"] = 2
                changed["iinaMagnetManaged"] = marker
                return changed
            },
            { info in
                var changed = info
                var marker = changed["iinaMagnetManaged"] as! [String: Any]
                marker["version"] = "2.0.0"
                changed["iinaMagnetManaged"] = marker
                return changed
            },
            { info in
                var changed = info
                var marker = changed["iinaMagnetManaged"] as! [String: Any]
                marker["contentManifestDigest"] = "sha256:INVALID"
                changed["iinaMagnetManaged"] = marker
                return changed
            },
        ]
        for mutation in mutations {
            let root = try makeBundledPluginTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let package = root.appendingPathComponent("anime4k.iinaplugin")
            try fixture.write(to: package)
            let infoURL = package.appendingPathComponent("Info.json")
            let info = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: infoURL)) as? [String: Any]
            )
            try JSONSerialization.data(withJSONObject: mutation(info), options: [.sortedKeys])
                .write(to: infoURL)
            expectCoreError {
                _ = try BundledPluginTrustedVerifier.verifyManagedPackage(
                    at: package,
                    fileSystem: fileSystem
                )
            }
        }
    }

    @Test func archiveEntryValidationAllowsSafeUnicodeAndRejectsUnsafeShapes() {
        let valid = [
            entry("Info.json"), entry("main.js"), entry("manifest.json"),
            entry("ui/空 格:sidebar.html"),
        ]
        do {
            try BundledPluginTrustedVerifier.validateArchiveEntries(valid)
        } catch {
            Issue.record("safe archive paths were rejected: \(error)")
        }

        let invalidPaths = [
            "../main.js", "/main.js", "ui/../main.js", "ui//main.js",
            "./main.js", "ui\\main.js", "ui/", "a\0b",
        ]
        for path in invalidPaths {
            expectCoreError {
                try BundledPluginTrustedVerifier.validateArchiveEntries([
                    entry("Info.json"), entry("main.js"), entry("manifest.json"), entry(path),
                ])
            }
        }
        expectCoreError {
            try BundledPluginTrustedVerifier.validateArchiveEntries([
                entry("Info.json"), entry("Info.json"), entry("main.js"), entry("manifest.json"),
            ])
        }
        for kind in [
            BundledPluginArchiveEntryKind.directory,
            .symbolicLink,
            .other,
        ] {
            expectCoreError {
                try BundledPluginTrustedVerifier.validateArchiveEntries([
                    entry("Info.json"), entry("main.js"), entry("manifest.json"),
                    .init(path: "unsafe", kind: kind, size: 0),
                ])
            }
        }
        expectCoreError {
            try BundledPluginTrustedVerifier.validateArchiveEntries([
                entry("Info.json"), entry("main.js"), entry("manifest.json"),
                .init(path: "executable.js", size: 1, posixPermissions: 0o755),
            ])
        }
    }

    private func entry(_ path: String) -> BundledPluginArchiveEntry {
        .init(path: path, size: 1, posixPermissions: 0o644)
    }

    private func replacing(
        _ catalog: BundledPluginCatalog,
        archive: BundledPluginCatalog.Archive? = nil,
        entries: [BundledPluginArchiveEntry]? = nil,
        identifier: String? = nil,
        packageSchemaVersion: Int? = nil,
        upstreamCommit: String? = nil
    ) -> BundledPluginCatalog {
        .init(
            archive: archive ?? catalog.archive,
            contentManifestDigest: catalog.contentManifestDigest,
            entries: entries ?? catalog.entries,
            identifier: identifier ?? catalog.identifier,
            packageSchemaVersion: packageSchemaVersion ?? catalog.packageSchemaVersion,
            upstreamCommit: upstreamCommit ?? catalog.upstreamCommit,
            version: catalog.version
        )
    }

    private func expectCoreError(_ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("expected verification failure")
        } catch is BundledPluginCoreError {
            // Expected.
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}

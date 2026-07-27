import Foundation
import Testing
@testable import IinaMagnet

@Suite struct BundledPluginTransactionTests {
    private let fileSystem = DarwinBundledPluginFileSystem()

    @Test func configurationKeepsEveryTransactionPathHiddenFromLoader() throws {
        let root = try makeBundledPluginTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try makeConfiguration(root: root)

        #expect(BundledPluginTransactionConfiguration.isLoaderVisible(configuration.canonicalName))
        for name in [configuration.stagingName, configuration.priorName, configuration.journalName] {
            #expect(BundledPluginTransactionConfiguration.isHiddenAndLoaderInvisible(name))
            #expect(!BundledPluginTransactionConfiguration.isLoaderVisible(name))
        }
    }

    @Test func freshInstallUsesExclusiveRenameAndIsIdempotent() throws {
        let fixture = try BundledPluginTestPackageFixture.make()
        let root = try makeBundledPluginTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinels = try createSentinels(at: root)
        let renamer = BundledPluginRecordingRenamer()
        let (transaction, configuration) = try makeTransaction(
            root: root,
            fixture: fixture,
            renamer: renamer
        )

        let outcome = try transaction.installFresh(archiveData: fixture.archiveData)
        let repeated = try transaction.installFresh(archiveData: fixture.archiveData)

        #expect(outcome.status == .committedFreshInstall)
        #expect(outcome.needsInventoryReload)
        #expect(outcome.adapterState == configuration.adapterState)
        #expect(repeated.status == .noChange)
        #expect(!repeated.needsInventoryReload)
        #expect(renamer.calls == [.exclusive])
        #expect(try bundledPluginLoaderVisibleNames(at: root) == [configuration.canonicalName])
        #expect(!fileSystem.itemExists(at: configuration.stagingURL))
        #expect(!fileSystem.itemExists(at: configuration.priorURL))
        #expect(!fileSystem.itemExists(at: configuration.journalURL))
        try verify(fixture, at: configuration.canonicalURL)
        try expectSentinelsUnchanged(sentinels)
    }

    @Test func canonicalAppearingAfterInventoryAbortsWithoutOverwrite() throws {
        let desired = try BundledPluginTestPackageFixture.make()
        let contender = try BundledPluginTestPackageFixture.make(
            version: "9.0.0",
            main: "contender"
        )
        let root = try makeBundledPluginTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let renamer = BundledPluginRecordingRenamer()
        let configuration = try makeConfiguration(root: root)
        let transaction = BundledPluginTransaction(
            configuration: configuration,
            fileSystem: fileSystem,
            renamer: renamer,
            extractor: BundledPluginFixtureExtractor(fixture: desired),
            validator: BundledPluginCatalogSetPackageValidator(
                desiredCatalog: desired.catalog,
                trustedManagedCatalogs: [desired.catalog],
                fileSystem: fileSystem
            ),
            checkpoint: { checkpoint in
                if checkpoint == .beforeCommit {
                    try contender.write(to: configuration.canonicalURL)
                }
            }
        )

        let outcome = try transaction.installFresh(archiveData: desired.archiveData)

        #expect(outcome.status == .needsReinventory)
        #expect(renamer.calls.isEmpty)
        #expect(try bundledPluginLoaderVisibleNames(at: root) == [configuration.canonicalName])
        try verify(contender, at: configuration.canonicalURL)
        #expect(!fileSystem.itemExists(at: configuration.stagingURL))
        #expect(!fileSystem.itemExists(at: configuration.journalURL))
    }

    @Test func exclusiveRenameEEXISTRaceAbortsAndKeepsContender() throws {
        let desired = try BundledPluginTestPackageFixture.make()
        let contender = try BundledPluginTestPackageFixture.make(
            version: "9.0.0",
            main: "atomic-race-contender"
        )
        let root = try makeBundledPluginTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try makeConfiguration(root: root)
        let renamer = BundledPluginRacingRenamer(contender: contender)
        let transaction = BundledPluginTransaction(
            configuration: configuration,
            fileSystem: fileSystem,
            renamer: renamer,
            extractor: BundledPluginFixtureExtractor(fixture: desired),
            validator: BundledPluginCatalogSetPackageValidator(
                desiredCatalog: desired.catalog,
                trustedManagedCatalogs: [desired.catalog],
                fileSystem: fileSystem
            )
        )

        let outcome = try transaction.installFresh(archiveData: desired.archiveData)

        #expect(outcome.status == .needsReinventory)
        #expect(renamer.didAttemptExclusiveRename)
        try verify(contender, at: configuration.canonicalURL)
        #expect(try bundledPluginLoaderVisibleNames(at: root) == [configuration.canonicalName])
        #expect(!fileSystem.itemExists(at: configuration.stagingURL))
        #expect(!fileSystem.itemExists(at: configuration.journalURL))
    }

    @Test func preJournalCrashesCleanlyRetryWithoutExposingStaging() throws {
        let fixture = try BundledPluginTestPackageFixture.make()
        for crashPoint in [
            BundledPluginTransactionCheckpoint.beforeStaging,
            .afterVerification,
        ] {
            let root = try makeBundledPluginTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let renamer = BundledPluginRecordingRenamer()
            let (transaction, configuration) = try makeTransaction(
                root: root,
                fixture: fixture,
                renamer: renamer,
                crashAt: crashPoint
            )
            expectInjectedCrash(crashPoint) {
                _ = try transaction.installFresh(archiveData: fixture.archiveData)
            }
            #expect(try bundledPluginLoaderVisibleNames(at: root).isEmpty)

            let (recovery, _) = try makeTransaction(
                root: root,
                fixture: fixture,
                renamer: renamer
            )
            #expect(try recovery.recover().status == .noChange)
            #expect(!fileSystem.itemExists(at: configuration.stagingURL))
            #expect(!fileSystem.itemExists(at: configuration.journalURL))
            #expect(try recovery.installFresh(archiveData: fixture.archiveData).status == .committedFreshInstall)
            try verify(fixture, at: configuration.canonicalURL)
        }
    }

    @Test func freshInstallRecoversBeforeAndAfterExclusiveRenameCrashes() throws {
        let fixture = try BundledPluginTestPackageFixture.make()
        for crashPoint in [
            BundledPluginTransactionCheckpoint.beforeCommit,
            .afterCommit,
        ] {
            let root = try makeBundledPluginTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let renamer = BundledPluginRecordingRenamer()
            let (transaction, configuration) = try makeTransaction(
                root: root,
                fixture: fixture,
                renamer: renamer,
                crashAt: crashPoint
            )
            expectInjectedCrash(crashPoint) {
                _ = try transaction.installFresh(archiveData: fixture.archiveData)
            }
            #expect(try bundledPluginLoaderVisibleNames(at: root).count == (crashPoint == .afterCommit ? 1 : 0))

            let (recovery, _) = try makeTransaction(
                root: root,
                fixture: fixture,
                renamer: renamer
            )
            let outcome = try recovery.recover()

            #expect(outcome.status == (crashPoint == .afterCommit
                ? .recoveredKeepingCanonical
                : .recoveredFreshInstall))
            #expect(try bundledPluginLoaderVisibleNames(at: root) == [configuration.canonicalName])
            try verify(fixture, at: configuration.canonicalURL)
            #expect(!fileSystem.itemExists(at: configuration.stagingURL))
            #expect(!fileSystem.itemExists(at: configuration.journalURL))
        }
    }

    @Test func recoveredHealthyFreshShellRestoresOnlyAMissingEnabledDefault() throws {
        let fixture = try BundledPluginTestPackageFixture.make()
        let root = try makeBundledPluginTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let renamer = BundledPluginRecordingRenamer()
        let (transaction, configuration) = try makeTransaction(
            root: root,
            fixture: fixture,
            renamer: renamer,
            crashAt: .afterCommit
        )
        expectInjectedCrash(.afterCommit) {
            _ = try transaction.installFresh(archiveData: fixture.archiveData)
        }
        let (recovery, _) = try makeTransaction(root: root, fixture: fixture, renamer: renamer)
        #expect(try recovery.recover().status == .recoveredKeepingCanonical)
        let verified = try BundledPluginTrustedVerifier.verifyInstalledPackage(
            at: configuration.canonicalURL,
            catalog: fixture.catalog,
            fileSystem: fileSystem
        )
        let snapshot = BundledPluginPackageSnapshot(
            directoryName: configuration.canonicalName,
            identifier: verified.identifier,
            marker: verified.marker,
            isHealthy: true
        )
        let missing = BundledPluginPolicy.evaluate(
            catalog: fixture.catalog,
            inventory: .init(forkPackages: [snapshot], storedEnabled: nil)
        )
        let explicitlyDisabled = BundledPluginPolicy.evaluate(
            catalog: fixture.catalog,
            inventory: .init(forkPackages: [snapshot], storedEnabled: false)
        )
        #expect(missing.shouldEnableFreshShell)
        #expect(!missing.preserveEnabledState)
        #expect(!explicitlyDisabled.shouldEnableFreshShell)
        #expect(explicitlyDisabled.preserveEnabledState)
    }

    @Test func replacementUsesOneSwapAndPreservesExternalState() throws {
        let old = try BundledPluginTestPackageFixture.make(
            version: "1.0.0",
            main: "old-main"
        )
        let desired = try BundledPluginTestPackageFixture.make(
            version: "2.0.0",
            main: "new-main"
        )
        let root = try makeBundledPluginTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try makeConfiguration(root: root)
        try old.write(to: configuration.canonicalURL)
        let sentinels = try createSentinels(at: root)
        let renamer = BundledPluginRecordingRenamer()
        let (transaction, _) = try makeTransaction(
            root: root,
            fixture: desired,
            managed: [old.catalog, desired.catalog],
            renamer: renamer
        )

        let outcome = try transaction.replace(archiveData: desired.archiveData)
        let repeated = try transaction.replace(archiveData: desired.archiveData)

        #expect(outcome.status == .committedReplacement)
        #expect(repeated.status == .noChange)
        #expect(renamer.calls == [.exclusive, .swap])
        #expect(outcome.adapterState == configuration.adapterState)
        #expect(try bundledPluginLoaderVisibleNames(at: root) == [configuration.canonicalName])
        try verify(desired, at: configuration.canonicalURL)
        try expectSentinelsUnchanged(sentinels)
    }

    @Test func beforeSwapCrashLeavesOldCanonicalAndRecoveryKeepsIt() throws {
        let old = try BundledPluginTestPackageFixture.make(version: "1.0.0", main: "old")
        let desired = try BundledPluginTestPackageFixture.make(version: "2.0.0", main: "new")
        let root = try makeBundledPluginTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try makeConfiguration(root: root)
        try old.write(to: configuration.canonicalURL)
        let renamer = BundledPluginRecordingRenamer()
        let (transaction, _) = try makeTransaction(
            root: root,
            fixture: desired,
            managed: [old.catalog, desired.catalog],
            renamer: renamer,
            crashAt: .beforeCommit
        )

        expectInjectedCrash(.beforeCommit) {
            _ = try transaction.replace(archiveData: desired.archiveData)
        }
        try verify(old, at: configuration.canonicalURL)
        #expect(renamer.calls == [.exclusive])
        #expect(try bundledPluginLoaderVisibleNames(at: root) == [configuration.canonicalName])

        let (recovery, _) = try makeTransaction(
            root: root,
            fixture: desired,
            managed: [old.catalog, desired.catalog],
            renamer: renamer
        )
        let outcome = try recovery.recover()
        #expect(outcome.status == .recoveredKeepingCanonical)
        #expect(renamer.calls == [.exclusive])
        try verify(old, at: configuration.canonicalURL)
        #expect(!fileSystem.itemExists(at: configuration.priorURL))
    }

    @Test func afterSwapCrashKeepsNewCanonicalDuringRecovery() throws {
        let old = try BundledPluginTestPackageFixture.make(version: "1.0.0", main: "old")
        let desired = try BundledPluginTestPackageFixture.make(version: "2.0.0", main: "new")
        let root = try makeBundledPluginTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try makeConfiguration(root: root)
        try old.write(to: configuration.canonicalURL)
        let renamer = BundledPluginRecordingRenamer()
        let (transaction, _) = try makeTransaction(
            root: root,
            fixture: desired,
            managed: [old.catalog, desired.catalog],
            renamer: renamer,
            crashAt: .afterCommit
        )

        expectInjectedCrash(.afterCommit) {
            _ = try transaction.replace(archiveData: desired.archiveData)
        }
        try verify(desired, at: configuration.canonicalURL)
        #expect(renamer.calls == [.exclusive, .swap])

        let (recovery, _) = try makeTransaction(
            root: root,
            fixture: desired,
            managed: [old.catalog, desired.catalog],
            renamer: renamer
        )
        let outcome = try recovery.recover()
        #expect(outcome.status == .recoveredKeepingCanonical)
        #expect(renamer.calls == [.exclusive, .swap])
        try verify(desired, at: configuration.canonicalURL)
        #expect(!fileSystem.itemExists(at: configuration.priorURL))
    }

    @Test func corruptPostSwapCanonicalAtomicallyRollsBackVerifiedPrior() throws {
        let old = try BundledPluginTestPackageFixture.make(version: "1.0.0", main: "old")
        let desired = try BundledPluginTestPackageFixture.make(version: "2.0.0", main: "new")
        let root = try makeBundledPluginTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try makeConfiguration(root: root)
        try old.write(to: configuration.canonicalURL)
        let renamer = BundledPluginRecordingRenamer()
        let (transaction, _) = try makeTransaction(
            root: root,
            fixture: desired,
            managed: [old.catalog, desired.catalog],
            renamer: renamer,
            crashAt: .afterCommit
        )
        expectInjectedCrash(.afterCommit) {
            _ = try transaction.replace(archiveData: desired.archiveData)
        }
        try Data("corrupt".utf8).write(
            to: configuration.canonicalURL.appendingPathComponent("main.js")
        )

        let (recovery, _) = try makeTransaction(
            root: root,
            fixture: desired,
            managed: [old.catalog, desired.catalog],
            renamer: renamer
        )
        let outcome = try recovery.recover()

        #expect(outcome.status == .recoveredPriorPackage)
        #expect(renamer.calls == [.exclusive, .swap, .swap])
        #expect(try bundledPluginLoaderVisibleNames(at: root) == [configuration.canonicalName])
        try verify(old, at: configuration.canonicalURL)
    }

    @Test func corruptCanonicalAndPriorFailClosedWithoutExposingPeer() throws {
        let old = try BundledPluginTestPackageFixture.make(version: "1.0.0", main: "old")
        let desired = try BundledPluginTestPackageFixture.make(version: "2.0.0", main: "new")
        let root = try makeBundledPluginTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try makeConfiguration(root: root)
        try old.write(to: configuration.canonicalURL)
        let renamer = BundledPluginRecordingRenamer()
        let (transaction, _) = try makeTransaction(
            root: root,
            fixture: desired,
            managed: [old.catalog, desired.catalog],
            renamer: renamer,
            crashAt: .afterCommit
        )
        expectInjectedCrash(.afterCommit) {
            _ = try transaction.replace(archiveData: desired.archiveData)
        }
        try Data("bad-new".utf8).write(
            to: configuration.canonicalURL.appendingPathComponent("main.js")
        )
        try Data("bad-old".utf8).write(
            to: configuration.priorURL.appendingPathComponent("main.js")
        )

        let (recovery, _) = try makeTransaction(
            root: root,
            fixture: desired,
            managed: [old.catalog, desired.catalog],
            renamer: renamer
        )
        expectCoreTransactionError {
            _ = try recovery.recover()
        }
        #expect(try bundledPluginLoaderVisibleNames(at: root) == [configuration.canonicalName])
        #expect(BundledPluginTransactionConfiguration.isHiddenAndLoaderInvisible(configuration.priorName))
    }

    @Test func recoveryIsRestartSafeAtRecoveryAndCleanupCheckpoints() throws {
        let old = try BundledPluginTestPackageFixture.make(version: "1.0.0", main: "old")
        let desired = try BundledPluginTestPackageFixture.make(version: "2.0.0", main: "new")
        let root = try makeBundledPluginTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try makeConfiguration(root: root)
        try old.write(to: configuration.canonicalURL)
        let renamer = BundledPluginRecordingRenamer()
        let (transaction, _) = try makeTransaction(
            root: root,
            fixture: desired,
            managed: [old.catalog, desired.catalog],
            renamer: renamer,
            crashAt: .afterCommit
        )
        expectInjectedCrash(.afterCommit) {
            _ = try transaction.replace(archiveData: desired.archiveData)
        }

        for crashPoint in [
            BundledPluginTransactionCheckpoint.duringRecovery,
            .beforeCleanup,
        ] {
            let (recovery, _) = try makeTransaction(
                root: root,
                fixture: desired,
                managed: [old.catalog, desired.catalog],
                renamer: renamer,
                crashAt: crashPoint
            )
            expectInjectedCrash(crashPoint) {
                _ = try recovery.recover()
            }
            try verify(desired, at: configuration.canonicalURL)
            #expect(fileSystem.itemExists(at: configuration.journalURL))
            #expect(try bundledPluginLoaderVisibleNames(at: root) == [configuration.canonicalName])
        }

        let (finalRecovery, _) = try makeTransaction(
            root: root,
            fixture: desired,
            managed: [old.catalog, desired.catalog],
            renamer: renamer
        )
        #expect(try finalRecovery.recover().status == .recoveredKeepingCanonical)
        #expect(!fileSystem.itemExists(at: configuration.journalURL))
        #expect(!fileSystem.itemExists(at: configuration.priorURL))
    }

    @Test func transactionRejectsCrossDeviceStagingBeforeAnyRename() throws {
        let fixture = try BundledPluginTestPackageFixture.make()
        let root = try makeBundledPluginTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try makeConfiguration(root: root)
        let crossDevice = BundledPluginCrossDeviceFileSystem(
            base: fileSystem,
            differingPath: configuration.stagingURL.path
        )
        let renamer = BundledPluginRecordingRenamer()
        let transaction = BundledPluginTransaction(
            configuration: configuration,
            fileSystem: crossDevice,
            renamer: renamer,
            extractor: BundledPluginFixtureExtractor(fixture: fixture),
            validator: BundledPluginCatalogSetPackageValidator(
                desiredCatalog: fixture.catalog,
                trustedManagedCatalogs: [fixture.catalog],
                fileSystem: crossDevice
            )
        )

        do {
            _ = try transaction.installFresh(archiveData: fixture.archiveData)
            Issue.record("cross-device transaction unexpectedly committed")
        } catch BundledPluginAtomicRenameError.crossDevice {
            // Expected.
        } catch {
            Issue.record("unexpected cross-device error: \(error)")
        }
        #expect(renamer.calls.isEmpty)
        #expect(try bundledPluginLoaderVisibleNames(at: root).isEmpty)
    }

    @Test func recoveryCheckpointsAndOrphanCleanupAreDeterministic() throws {
        let fixture = try BundledPluginTestPackageFixture.make()
        let root = try makeBundledPluginTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try makeConfiguration(root: root)
        let sentinels = try createSentinels(at: root)
        try FileManager.default.createDirectory(at: configuration.stagingURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: configuration.priorURL, withIntermediateDirectories: false)
        let renamer = BundledPluginRecordingRenamer()
        var checkpoints: [BundledPluginTransactionCheckpoint] = []
        let transaction = BundledPluginTransaction(
            configuration: configuration,
            fileSystem: fileSystem,
            renamer: renamer,
            extractor: BundledPluginFixtureExtractor(fixture: fixture),
            validator: BundledPluginCatalogSetPackageValidator(
                desiredCatalog: fixture.catalog,
                trustedManagedCatalogs: [fixture.catalog],
                fileSystem: fileSystem
            ),
            checkpoint: { checkpoints.append($0) }
        )

        let outcome = try transaction.recover()

        #expect(outcome.status == .noChange)
        #expect(checkpoints.isEmpty)
        #expect(!fileSystem.itemExists(at: configuration.stagingURL))
        #expect(!fileSystem.itemExists(at: configuration.priorURL))
        try expectSentinelsUnchanged(sentinels)
    }

    private func makeConfiguration(root: URL) throws -> BundledPluginTransactionConfiguration {
        try .init(
            root: root,
            adapterState: .init(enabled: false, order: ["first", "anime4k", "last"])
        )
    }

    private func makeTransaction(
        root: URL,
        fixture: BundledPluginTestPackageFixture,
        managed: [BundledPluginCatalog]? = nil,
        renamer: any BundledPluginAtomicRenamer,
        crashAt: BundledPluginTransactionCheckpoint? = nil
    ) throws -> (BundledPluginTransaction, BundledPluginTransactionConfiguration) {
        let configuration = try makeConfiguration(root: root)
        let validator = BundledPluginCatalogSetPackageValidator(
            desiredCatalog: fixture.catalog,
            trustedManagedCatalogs: managed ?? [fixture.catalog],
            fileSystem: fileSystem
        )
        return (
            BundledPluginTransaction(
                configuration: configuration,
                fileSystem: fileSystem,
                renamer: renamer,
                extractor: BundledPluginFixtureExtractor(fixture: fixture),
                validator: validator,
                checkpoint: { checkpoint in
                    if checkpoint == crashAt { throw BundledPluginInjectedCrash(checkpoint) }
                }
            ),
            configuration
        )
    }

    private func verify(_ fixture: BundledPluginTestPackageFixture, at url: URL) throws {
        _ = try BundledPluginTrustedVerifier.verifyInstalledPackage(
            at: url,
            catalog: fixture.catalog,
            fileSystem: fileSystem
        )
    }

    private func expectInjectedCrash(
        _ checkpoint: BundledPluginTransactionCheckpoint,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("expected injected crash at \(checkpoint)")
        } catch let error as BundledPluginInjectedCrash {
            #expect(error.checkpoint == checkpoint)
        } catch {
            Issue.record("unexpected crash error: \(error)")
        }
    }

    private func expectCoreTransactionError(_ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("expected transaction failure")
        } catch is BundledPluginCoreError {
            // Expected.
        } catch {
            Issue.record("unexpected transaction error: \(error)")
        }
    }

    private func createSentinels(at root: URL) throws -> [URL: Data] {
        let values = [
            root.appendingPathComponent(".preferences/sentinel.json"): Data("prefs".utf8),
            root.appendingPathComponent(".data/sentinel.bin"): Data("data".utf8),
        ]
        for (url, data) in values {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
        return values
    }

    private func expectSentinelsUnchanged(_ sentinels: [URL: Data]) throws {
        for (url, data) in sentinels {
            #expect(try Data(contentsOf: url) == data)
        }
    }
}

private struct BundledPluginCrossDeviceFileSystem: BundledPluginFileSystem {
    let base: DarwinBundledPluginFileSystem
    let differingPath: String

    func itemExists(at url: URL) -> Bool { base.itemExists(at: url) }
    func itemKind(at url: URL) throws -> BundledPluginFileKind { try base.itemKind(at: url) }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func readData(at url: URL) throws -> Data { try base.readData(at: url) }
    func writeDataAtomicallyAndSync(_ data: Data, to url: URL) throws {
        try base.writeDataAtomicallyAndSync(data, to: url)
    }
    func syncDirectory(at url: URL) throws { try base.syncDirectory(at: url) }
    func deviceIdentifier(at url: URL) throws -> UInt64 {
        url.path == differingPath ? 2 : 1
    }
    func recursiveEntries(at root: URL) throws -> [BundledPluginArchiveEntry] {
        try base.recursiveEntries(at: root)
    }
}

private final class BundledPluginRacingRenamer: BundledPluginAtomicRenamer {
    let contender: BundledPluginTestPackageFixture
    private(set) var didAttemptExclusiveRename = false
    private let base = DarwinBundledPluginAtomicRenamer()

    init(contender: BundledPluginTestPackageFixture) {
        self.contender = contender
    }

    func renameExclusive(from source: URL, to destination: URL) throws {
        didAttemptExclusiveRename = true
        try contender.write(to: destination)
        try base.renameExclusive(from: source, to: destination)
    }

    func swap(_ first: URL, _ second: URL) throws {
        try base.swap(first, second)
    }
}

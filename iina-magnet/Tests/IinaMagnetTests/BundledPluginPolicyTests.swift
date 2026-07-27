import Foundation
import Testing
@testable import IinaMagnet

@Suite struct BundledPluginSemanticVersionTests {
    @Test func semVerPrecedenceMatchesSpecification() throws {
        let ordered = try [
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0",
        ].map(BundledPluginSemanticVersion.init(parsing:))

        #expect(ordered.sorted() == ordered)
        let buildOne = try BundledPluginSemanticVersion(parsing: "1.0.0+one")
        let buildTwo = try BundledPluginSemanticVersion(parsing: "1.0.0+two")
        #expect(!(buildOne < buildTwo))
        #expect(!(buildTwo < buildOne))
    }

    @Test func malformedSemVerIsRejectedStrictly() {
        let malformed = [
            "", "1", "1.0", "1.0.0.0", "01.0.0", "1.01.0", "1.0.01",
            "1.0.0-", "1.0.0+", "1.0.0-alpha..one", "1.0.0-01",
            "1.0.0+meta..one", "1.0.0 alpha", "１.0.0",
        ]
        for value in malformed {
            do {
                _ = try BundledPluginSemanticVersion(parsing: value)
                Issue.record("accepted malformed semantic version: \(value)")
            } catch is BundledPluginCoreError {
                // Expected.
            } catch {
                Issue.record("unexpected error for \(value): \(error)")
            }
        }
    }
}

@Suite struct BundledPluginPolicyTests {
    @Test func freshInstallEnablesOnlyANewShellAndPreservesOrder() throws {
        let catalog = try makeCatalog("1.0.0")
        let order = ["other.plugin", catalog.identifier]
        let fresh = BundledPluginPolicy.evaluate(
            catalog: catalog,
            inventory: .init(storedEnabled: nil, storedOrder: order)
        )
        let explicitlyDisabled = BundledPluginPolicy.evaluate(
            catalog: catalog,
            inventory: .init(storedEnabled: false, storedOrder: order)
        )

        #expect(fresh.state == .absent)
        #expect(fresh.action == .install)
        #expect(fresh.shouldEnableFreshShell)
        #expect(!fresh.preserveEnabledState)
        #expect(fresh.preservedOrder == order)
        #expect(!explicitlyDisabled.shouldEnableFreshShell)
        #expect(explicitlyDisabled.preserveEnabledState)
        #expect(explicitlyDisabled.preservedOrder == order)
    }

    @Test func healthySameVersionIsNoOpForEitherEnabledState() throws {
        let catalog = try makeCatalog("1.0.0")
        for enabled in [true, false] {
            let decision = BundledPluginPolicy.evaluate(
                catalog: catalog,
                inventory: .init(
                    forkPackages: [try snapshot("1.0.0", digest: catalog.contentManifestDigest)],
                    storedEnabled: enabled,
                    storedOrder: ["one", "two"]
                )
            )
            #expect(decision.state == .managedHealthySameVersion)
            #expect(decision.action == .noOp)
            #expect(decision.preserveEnabledState)
            #expect(decision.preservedOrder == ["one", "two"])
        }
    }

    @Test func healthySameVersionRestoresOnlyAMissingShellEnabledDefault() throws {
        let catalog = try makeCatalog("1.0.0")
        let installed = try snapshot("1.0.0", digest: catalog.contentManifestDigest)
        let missing = BundledPluginPolicy.evaluate(
            catalog: catalog,
            inventory: .init(forkPackages: [installed], storedEnabled: nil)
        )
        let explicitlyDisabled = BundledPluginPolicy.evaluate(
            catalog: catalog,
            inventory: .init(forkPackages: [installed], storedEnabled: false)
        )

        #expect(missing.state == .managedHealthySameVersion)
        #expect(missing.action == .noOp)
        #expect(missing.shouldEnableFreshShell)
        #expect(!missing.preserveEnabledState)
        #expect(!explicitlyDisabled.shouldEnableFreshShell)
        #expect(explicitlyDisabled.preserveEnabledState)
    }

    @Test func buildMetadataDoesNotCauseUpgradeOrDowngrade() throws {
        let catalog = try makeCatalog("1.0.0+bundled")
        let decision = BundledPluginPolicy.evaluate(
            catalog: catalog,
            inventory: .init(forkPackages: [try snapshot(
                "1.0.0+installed",
                digest: catalog.contentManifestDigest
            )])
        )
        #expect(decision.state == .managedHealthySameVersion)
        #expect(decision.action == .noOp)
    }

    @Test func healthyOlderVersionUpgradesWithoutComparingNewManifestDigest() throws {
        let catalog = try makeCatalog("2.0.0")
        let installed = try snapshot("1.0.0", digest: digest("1"))
        let decision = BundledPluginPolicy.evaluate(
            catalog: catalog,
            inventory: .init(forkPackages: [installed], storedEnabled: false)
        )

        #expect(decision.state == .managedOlder)
        #expect(decision.action == .upgrade)
        #expect(decision.preserveEnabledState)
    }

    @Test func healthyNewerVersionIsNeverDowngraded() throws {
        let catalog = try makeCatalog("1.0.0")
        let decision = BundledPluginPolicy.evaluate(
            catalog: catalog,
            inventory: .init(forkPackages: [try snapshot("2.0.0", digest: digest("2"))])
        )
        #expect(decision.state == .managedNewer)
        #expect(decision.action == .noOp)
        #expect(decision.disableIdentifiers.isEmpty)
    }

    @Test func corruptCurrentOrOlderPackageRepairsButCorruptNewerFailsOff() throws {
        let catalog = try makeCatalog("2.0.0")
        let sameDigestMismatch = BundledPluginPolicy.evaluate(
            catalog: catalog,
            inventory: .init(forkPackages: [try snapshot("2.0.0", digest: digest("a"))])
        )
        let oldUnhealthy = BundledPluginPolicy.evaluate(
            catalog: catalog,
            inventory: .init(forkPackages: [try snapshot("1.0.0", healthy: false, digest: digest("b"))])
        )
        let newerUnhealthy = BundledPluginPolicy.evaluate(
            catalog: try makeCatalog("1.0.0"),
            inventory: .init(forkPackages: [try snapshot("2.0.0", healthy: false, digest: digest("c"))])
        )

        #expect(sameDigestMismatch.state == .managedCorrupt)
        #expect(sameDigestMismatch.action == .repair)
        #expect(oldUnhealthy.state == .managedCorrupt)
        #expect(oldUnhealthy.action == .repair)
        #expect(newerUnhealthy.state == .managedCorrupt)
        #expect(newerUnhealthy.action == .noOp)
        #expect(newerUnhealthy.disableIdentifiers == [catalog.identifier])
    }

    @Test func unmanagedAndConflictStatesFailOffWithoutMutatingOrder() throws {
        let catalog = try makeCatalog("1.0.0")
        let order = ["first", "second"]
        let unmanaged = BundledPluginPolicy.evaluate(
            catalog: catalog,
            inventory: .init(
                forkPackages: [.init(
                    directoryName: "fork.iinaplugin",
                    identifier: catalog.identifier,
                    marker: nil,
                    isHealthy: true
                )],
                storedOrder: order
            )
        )
        let community = BundledPluginPolicy.evaluate(
            catalog: catalog,
            inventory: .init(
                communityPackages: [.init(
                    directoryName: "community.iinaplugin",
                    identifier: "com.yorkyang2333.anime4k",
                    marker: nil,
                    isHealthy: true
                )],
                storedOrder: order
            )
        )

        #expect(unmanaged.state == .unmanagedSameIdentifier)
        #expect(unmanaged.pendingResolution == .unmanagedReplacement)
        #expect(unmanaged.disableIdentifiers == [catalog.identifier])
        #expect(community.state == .communityConflict)
        #expect(community.pendingResolution == .communityMigration)
        #expect(Set(community.disableIdentifiers) == [catalog.identifier, "com.yorkyang2333.anime4k"])
        #expect(unmanaged.preservedOrder == order)
        #expect(community.preservedOrder == order)
    }

    @Test func multipleForkOwnersDisableEveryConflictIdentifier() throws {
        let catalog = try makeCatalog("1.0.0")
        let fork = try snapshot("1.0.0", digest: catalog.contentManifestDigest)
        let community = BundledPluginPackageSnapshot(
            directoryName: "community.iinaplugin",
            identifier: "com.yorkyang2333.anime4k",
            marker: nil,
            isHealthy: true
        )
        let decision = BundledPluginPolicy.evaluate(
            catalog: catalog,
            inventory: .init(forkPackages: [fork, fork], communityPackages: [community])
        )
        #expect(decision.state == .multipleOwners)
        #expect(decision.pendingResolution == .multipleOwners)
        #expect(Set(decision.disableIdentifiers) == [catalog.identifier, community.identifier])
    }

    @Test func repeatedEvaluationIsIdempotent() throws {
        let catalog = try makeCatalog("2.0.0")
        let inventory = BundledPluginInventory(
            forkPackages: [try snapshot("1.0.0", digest: digest("d"))],
            storedEnabled: false,
            storedOrder: ["stable"]
        )
        #expect(BundledPluginPolicy.evaluate(catalog: catalog, inventory: inventory)
            == BundledPluginPolicy.evaluate(catalog: catalog, inventory: inventory))
    }

    private func makeCatalog(_ version: String) throws -> BundledPluginCatalog {
        let parsed = try BundledPluginSemanticVersion(parsing: version)
        return .init(
            archive: .init(file: "anime4k.iinaplgz", sha256: digest("e"), size: 1),
            contentManifestDigest: digest("f"),
            identifier: BundledPluginTrustRequirements.anime4K.identifier,
            packageSchemaVersion: 1,
            upstreamCommit: BundledPluginTrustRequirements.anime4K.upstreamCommit,
            version: parsed
        )
    }

    private func snapshot(
        _ version: String,
        healthy: Bool = true,
        digest contentDigest: String
    ) throws -> BundledPluginPackageSnapshot {
        .init(
            directoryName: "io.iina.magnet.anime4k.iinaplugin",
            identifier: BundledPluginTrustRequirements.anime4K.identifier,
            marker: .init(
                contentManifestDigest: contentDigest,
                owner: BundledPluginTrustRequirements.anime4K.owner,
                packageSchemaVersion: 1,
                version: try .init(parsing: version)
            ),
            isHealthy: healthy
        )
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: character, count: 64)
    }
}

import Foundation

public enum BundledPluginPolicy {
    public static func evaluate(
        catalog: BundledPluginCatalog,
        inventory: BundledPluginInventory,
        communityIdentifier: String = "com.yorkyang2333.anime4k"
    ) -> BundledPluginDecision {
        let order = inventory.storedOrder
        let forkIdentifier = catalog.identifier
        let communityIsPresent = !inventory.communityPackages.isEmpty

        if inventory.forkPackages.count > 1 {
            return .init(
                state: .multipleOwners,
                action: .resolveMultipleOwners,
                disableIdentifiers: communityIsPresent ? [forkIdentifier, communityIdentifier] : [forkIdentifier],
                pendingResolution: .multipleOwners,
                preservedOrder: order
            )
        }
        if communityIsPresent {
            return .init(
                state: .communityConflict,
                action: .requireCommunityMigration,
                disableIdentifiers: [forkIdentifier, communityIdentifier],
                pendingResolution: .communityMigration,
                preservedOrder: order
            )
        }
        guard let installed = inventory.forkPackages.first else {
            return .init(
                state: .absent,
                action: .install,
                shouldEnableFreshShell: inventory.storedEnabled == nil,
                preserveEnabledState: inventory.storedEnabled != nil,
                preservedOrder: order
            )
        }
        guard let marker = installed.marker,
              installed.identifier == forkIdentifier,
              marker.owner == BundledPluginTrustRequirements.anime4K.owner,
              marker.packageSchemaVersion == catalog.packageSchemaVersion else {
            return .init(
                state: .unmanagedSameIdentifier,
                action: .requireUnmanagedReplacement,
                disableIdentifiers: [forkIdentifier],
                pendingResolution: .unmanagedReplacement,
                preservedOrder: order
            )
        }
        let versionsHaveSamePrecedence = !(marker.version < catalog.version) && !(catalog.version < marker.version)
        if versionsHaveSamePrecedence {
            guard installed.isHealthy,
                  marker.contentManifestDigest == catalog.contentManifestDigest else {
                return .init(state: .managedCorrupt, action: .repair, preservedOrder: order)
            }
            return .init(
                state: .managedHealthySameVersion,
                action: .noOp,
                shouldEnableFreshShell: inventory.storedEnabled == nil,
                preserveEnabledState: inventory.storedEnabled != nil,
                preservedOrder: order
            )
        }
        if marker.version < catalog.version {
            guard installed.isHealthy else {
                return .init(state: .managedCorrupt, action: .repair, preservedOrder: order)
            }
            return .init(state: .managedOlder, action: .upgrade, preservedOrder: order)
        }
        guard installed.isHealthy else {
            // An older app bundle cannot safely repair a newer package without
            // downgrading it. Fail off and leave resolution to a newer app.
            return .init(
                state: .managedCorrupt,
                action: .noOp,
                disableIdentifiers: [forkIdentifier],
                preservedOrder: order
            )
        }
        return .init(state: .managedNewer, action: .noOp, preservedOrder: order)
    }
}

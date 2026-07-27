//
//  BundledPluginManager.swift
//  iina
//
//  Keeps the fork-managed Anime4K package trustworthy and loader-safe before
//  any JavaScript plugin instance can be created.
//

import Cocoa
import IinaMagnet

final class BundledPluginManager {
  static let shared = BundledPluginManager()

  private static let communityIdentifier = "com.yorkyang2333.anime4k"
  private static let catalogFileName = "anime4k.catalog.json"
  private static let trustHistoryFileName = "anime4k.trusted-catalogs.json"
  private static let canonicalDirectoryName = "io.iina.magnet.anime4k.iinaplugin"
  private static let communityMigrationAcceptedDefaultsKey =
    "IINAMagnet.BundledPlugin.Anime4K.CommunityMigrationAccepted"

  struct PendingResolution {
    let kind: BundledPluginPendingResolution
    let catalogVersion: String
    let forkDirectories: [String]
    let communityDirectories: [String]
  }

  enum PreparationResult: Equatable {
    case notRun
    case noChange
    case installed
    case replaced
    case recovered
    case pending(BundledPluginPendingResolution)
    case failed(String)
  }

  private let expected = BundledPluginTrustRequirements.anime4K
  private let fileSystem = DarwinBundledPluginFileSystem()
  private let renamer = DarwinBundledPluginAtomicRenamer()
  private let extractor = DittoBundledPluginArchiveExtractor()
  private let defaults = UserDefaults.standard

  private(set) var pendingResolution: PendingResolution?
  private(set) var preparationResult: PreparationResult = .notRun

  private var prepared = false
  private var loadedStaticInventory = false
  private var resolutionPresented = false
  private var resolutionInventoryRefreshed = false
  private var activeResolutionAlert: NSAlert?

  private init() {}

  static func managesBundledArchive(named name: String) -> Bool {
    name == BundledPluginTrustRequirements.anime4K.archiveFileName
  }

  /// Runs before the first access to `JavascriptPlugin.plugins`. All inventory
  /// here is deliberately raw filesystem/defaults state so conflicts can be
  /// disabled before the loader is allowed to create plugin objects.
  func prepare() {
    guard !prepared else { return }
    prepared = true

    do {
      let assets = try loadTrustedAssets()
      var inventory = makePolicyInventory(try makeRawInventory(
        catalog: assets.catalog,
        trustedCatalogs: assets.trustedCatalogs
      ))
      let adapterState = BundledPluginAdapterState(
        enabled: inventory.storedEnabled,
        order: inventory.storedOrder
      )
      let transaction = try makeTransaction(assets: assets, adapterState: adapterState)
      var successfulStatuses: [BundledPluginTransactionStatus] = []

      // Recovery is evaluated before policy so a committed canonical package
      // is the inventory source of truth. With no journal this only removes
      // stale hidden transaction paths and reports no change.
      let recovery = try transaction.recover()
      if isSuccessfulMutation(recovery.status) {
        successfulStatuses.append(recovery.status)
        inventory = makePolicyInventory(try makeRawInventory(
          catalog: assets.catalog,
          trustedCatalogs: assets.trustedCatalogs
        ))
      }

      var decision = BundledPluginPolicy.evaluate(catalog: assets.catalog, inventory: inventory)
      disableBeforeStaticLoad(decision.disableIdentifiers)
      recordPending(decision.pendingResolution, catalog: assets.catalog, inventory: inventory)

      let outcome: BundledPluginTransactionOutcome?
      switch decision.action {
      case .install:
        outcome = try transaction.installFresh(archiveData: assets.archiveData)
      case .upgrade, .repair:
        outcome = try transaction.replace(archiveData: assets.archiveData)
      case .noOp, .requireUnmanagedReplacement, .requireCommunityMigration, .resolveMultipleOwners:
        outcome = nil
      }

      if let outcome {
        if outcome.status == .needsReinventory {
          inventory = makePolicyInventory(try makeRawInventory(
            catalog: assets.catalog,
            trustedCatalogs: assets.trustedCatalogs
          ))
          decision = BundledPluginPolicy.evaluate(catalog: assets.catalog, inventory: inventory)
          disableBeforeStaticLoad(decision.disableIdentifiers)
          recordPending(decision.pendingResolution, catalog: assets.catalog, inventory: inventory)
        } else if isSuccessfulMutation(outcome.status) {
          successfulStatuses.append(outcome.status)
          inventory = makePolicyInventory(try makeRawInventory(
            catalog: assets.catalog,
            trustedCatalogs: assets.trustedCatalogs
          ))
          decision = BundledPluginPolicy.evaluate(catalog: assets.catalog, inventory: inventory)
          disableBeforeStaticLoad(decision.disableIdentifiers)
          recordPending(decision.pendingResolution, catalog: assets.catalog, inventory: inventory)
        }
      }

      // This final pure-policy application also repairs the narrow restart
      // window where a healthy package was committed before its enabled key.
      // An explicit false and every conflict/fail-off decision remain false.
      if decision.shouldEnableFreshShell {
        defaults.set(true, forKey: enabledDefaultsKey(expected.identifier))
      }

      // At this point AppDelegate has not touched the lazy static inventory.
      // Initializing it once after the final filesystem commit avoids calling
      // recreateAllPlugins() on an uninitialized static property, which would
      // perform an old load followed by a second load.
      if !successfulStatuses.isEmpty {
        loadFinalStaticInventoryOnce()
      }

      if let pending = pendingResolution {
        preparationResult = .pending(pending.kind)
      } else {
        preparationResult = summarize(successfulStatuses)
      }
    } catch {
      // A missing/corrupt bundled asset or failed filesystem transaction must
      // never allow either renderer to start later in this launch.
      disableBeforeStaticLoad([expected.identifier, Self.communityIdentifier])
      pendingResolution = nil
      preparationResult = .failed(error.localizedDescription)
      Logger.log("Bundled Anime4K preparation failed: \(error.localizedDescription)", level: .error)
    }
  }

  /// Presents the explicit migration/replacement choice without blocking app
  /// readiness. Missing UI, dismissal, and import failure all retain the
  /// fail-off defaults written by `prepare()` and keep structured pending state.
  func presentPendingResolution() {
    guard let pending = pendingResolution, !resolutionPresented else { return }
    resolutionPresented = true
    present(pending, remainingWindowAttempts: 20)
  }

  private func present(_ pending: PendingResolution, remainingWindowAttempts: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self, self.pendingResolution?.kind == pending.kind else { return }
      guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else {
        if remainingWindowAttempts > 1 {
          self.present(pending, remainingWindowAttempts: remainingWindowAttempts - 1)
        } else {
          self.resolutionPresented = false
          Logger.log(
            "Bundled Anime4K resolution pending (\(pending.kind.rawValue)); no presentation window became ready. Both renderers remain disabled.",
            level: .warning
          )
        }
        return
      }

      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Anime4K plugin conflict"
      switch pending.kind {
      case .communityMigration:
        alert.informativeText = "Migrate supported Anime4K preferences to IINA Magnet? The community plugin will remain installed but disabled."
        alert.addButton(withTitle: "Migrate")
        alert.addButton(withTitle: "Cancel")
      case .unmanagedReplacement:
        alert.informativeText = "Replace the unmanaged plugin with the verified IINA Magnet package? The existing package will be preserved as a hidden backup."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
      case .multipleOwners:
        alert.informativeText = "Multiple plugins claim the managed Anime4K identifier. Disable the duplicates in Plugin Settings before continuing."
        alert.addButton(withTitle: "OK")
      }
      self.activeResolutionAlert = alert
      alert.beginSheetModal(for: window) { [weak self] response in
        guard let self else { return }
        self.activeResolutionAlert = nil
        if pending.kind == .multipleOwners {
          self.keepBothOwnersDisabled()
          self.resolutionPresented = false
          return
        }
        guard response == .alertFirstButtonReturn else {
          self.keepBothOwnersDisabled()
          self.resolutionPresented = false
          return
        }
        self.accept(pending)
      }
    }
  }

  private typealias TrustedAssets = (
    catalog: BundledPluginCatalog,
    archiveData: Data,
    trustedCatalogs: [BundledPluginCatalog]
  )

  private func loadTrustedAssets() throws -> TrustedAssets {
    guard let resources = Bundle.main.resourceURL else {
      throw BundledPluginCoreError.invalidCatalog("app resource directory is unavailable")
    }
    let plugins = resources.appendingPathComponent("plugins", isDirectory: true)
    let catalogURL = plugins.appendingPathComponent(Self.catalogFileName, isDirectory: false)
    let catalogData = try Data(contentsOf: catalogURL, options: [.mappedIfSafe])
    let catalog = try BundledPluginTrustedVerifier.decodeCatalog(catalogData)
    let historyURL = plugins.appendingPathComponent(Self.trustHistoryFileName, isDirectory: false)
    let historyData = try Data(contentsOf: historyURL, options: [.mappedIfSafe])
    let history = try BundledPluginTrustedVerifier.decodeTrustHistory(historyData)
    let trustedCatalogs = try BundledPluginTrustedVerifier.verifyTrustHistory(history, expected: expected)
    let archiveURL = plugins.appendingPathComponent(catalog.archive.file, isDirectory: false)
    let archiveData = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
    try BundledPluginTrustedVerifier.verifyCatalog(catalog, archiveData: archiveData, expected: expected)
    guard trustedCatalogs.contains(catalog) else {
      throw BundledPluginCoreError.invalidCatalog("trust history does not contain the current catalog")
    }
    return (catalog, archiveData, trustedCatalogs)
  }

  private func makeRawInventory(
    catalog: BundledPluginCatalog,
    trustedCatalogs: [BundledPluginCatalog]
  ) throws -> BundledPluginInventory {
    let root = Utility.pluginsURL
    let urls = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    )
    var forks: [BundledPluginPackageSnapshot] = []
    var communities: [BundledPluginPackageSnapshot] = []
    let validator = BundledPluginCatalogSetPackageValidator(
      desiredCatalog: catalog,
      trustedManagedCatalogs: trustedCatalogs,
      fileSystem: fileSystem,
      expected: expected
    )

    for url in urls where isLoaderVisiblePackage(url) {
      let isCanonicalName = url.lastPathComponent == Self.canonicalDirectoryName
      guard let raw = rawInfo(at: url) else {
        // A loader-visible canonical directory with unreadable/malformed Info
        // is an unmanaged conflict, never an absent install target.
        if isCanonicalName {
          forks.append(.init(
            directoryName: url.lastPathComponent,
            identifier: catalog.identifier,
            marker: nil,
            isHealthy: false
          ))
        }
        continue
      }
      if raw.identifier == catalog.identifier || isCanonicalName {
        let isCanonical = isCanonicalName && raw.identifier == catalog.identifier &&
          url.pathExtension == "iinaplugin" && !isSymbolicLink(url)
        let marker = isCanonical ? raw.marker : nil
        let healthy = isCanonical && marker != nil && validator.validateManagedPackage(at: url)
        forks.append(.init(
          directoryName: url.lastPathComponent,
          identifier: raw.identifier,
          marker: marker,
          isHealthy: healthy
        ))
      } else if raw.identifier == Self.communityIdentifier {
        communities.append(.init(
          directoryName: url.lastPathComponent,
          identifier: raw.identifier,
          marker: nil,
          isHealthy: true
        ))
      }
    }

    let enabledObject = defaults.object(forKey: enabledDefaultsKey(catalog.identifier))
    let storedEnabled = enabledObject == nil ? nil : defaults.bool(forKey: enabledDefaultsKey(catalog.identifier))
    let storedOrder = defaults.stringArray(forKey: "PluginOrder") ?? []
    return .init(
      forkPackages: forks.sorted { $0.directoryName < $1.directoryName },
      communityPackages: communities.sorted { $0.directoryName < $1.directoryName },
      storedEnabled: storedEnabled,
      storedOrder: storedOrder
    )
  }

  /// A successful migration leaves the community package installed but
  /// disabled. Ignore that known-safe disabled owner on later launches. If the
  /// user explicitly enables it again, revoke the acceptance so normal policy
  /// returns to the conflict prompt and disables both renderers before load.
  private func makePolicyInventory(
    _ inventory: BundledPluginInventory
  ) -> BundledPluginInventory {
    guard !inventory.communityPackages.isEmpty,
          defaults.bool(forKey: Self.communityMigrationAcceptedDefaultsKey) else {
      return inventory
    }
    if defaults.bool(forKey: enabledDefaultsKey(Self.communityIdentifier)) {
      defaults.removeObject(forKey: Self.communityMigrationAcceptedDefaultsKey)
      return inventory
    }
    disableBeforeStaticLoad([Self.communityIdentifier])
    return .init(
      forkPackages: inventory.forkPackages,
      communityPackages: [],
      storedEnabled: inventory.storedEnabled,
      storedOrder: inventory.storedOrder
    )
  }

  private func makeTransaction(
    assets: TrustedAssets,
    adapterState: BundledPluginAdapterState
  ) throws -> BundledPluginTransaction {
    let configuration = try BundledPluginTransactionConfiguration(
      root: Utility.pluginsURL,
      canonicalName: Self.canonicalDirectoryName,
      adapterState: adapterState
    )
    let validator = BundledPluginCatalogSetPackageValidator(
      desiredCatalog: assets.catalog,
      trustedManagedCatalogs: assets.trustedCatalogs,
      fileSystem: fileSystem,
      expected: expected
    )
    return BundledPluginTransaction(
      configuration: configuration,
      fileSystem: fileSystem,
      renamer: renamer,
      extractor: extractor,
      validator: validator
    )
  }

  private func isLoaderVisiblePackage(_ url: URL) -> Bool {
    guard !url.lastPathComponent.hasPrefix(".") else { return false }
    let allowedExtension = url.pathExtension == "iinaplugin" || url.pathExtension == "iinaplugin-dev"
    var isDirectory: ObjCBool = false
    return allowedExtension && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  private func isSymbolicLink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }

  private func rawInfo(at packageURL: URL) -> (identifier: String, marker: BundledPluginManagedMarker?)? {
    let infoURL = packageURL.appendingPathComponent("Info.json", isDirectory: false)
    guard let data = try? Data(contentsOf: infoURL, options: [.mappedIfSafe]),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let identifier = object["identifier"] as? String else { return nil }
    var marker: BundledPluginManagedMarker?
    if let value = object["iinaMagnetManaged"],
       JSONSerialization.isValidJSONObject(value),
       let markerData = try? JSONSerialization.data(withJSONObject: value) {
      marker = try? JSONDecoder().decode(BundledPluginManagedMarker.self, from: markerData)
    }
    return (identifier, marker)
  }

  private func enabledDefaultsKey(_ identifier: String) -> String {
    "PluginEnabled." + identifier
  }

  private func disableBeforeStaticLoad(_ identifiers: [String]) {
    for identifier in Set(identifiers) {
      defaults.set(false, forKey: enabledDefaultsKey(identifier))
    }
  }

  private func recordPending(
    _ kind: BundledPluginPendingResolution?,
    catalog: BundledPluginCatalog,
    inventory: BundledPluginInventory
  ) {
    guard let kind else {
      pendingResolution = nil
      return
    }
    pendingResolution = .init(
      kind: kind,
      catalogVersion: catalog.version.description,
      forkDirectories: inventory.forkPackages.map(\.directoryName),
      communityDirectories: inventory.communityPackages.map(\.directoryName)
    )
  }

  private func isSuccessfulMutation(_ status: BundledPluginTransactionStatus) -> Bool {
    switch status {
    case .committedFreshInstall, .committedReplacement, .recoveredKeepingCanonical,
         .recoveredFreshInstall, .recoveredPriorPackage:
      return true
    case .noChange, .needsReinventory:
      return false
    }
  }

  private func loadFinalStaticInventoryOnce() {
    guard !loadedStaticInventory else { return }
    loadedStaticInventory = true
    _ = JavascriptPlugin.plugins
  }

  private func summarize(_ statuses: [BundledPluginTransactionStatus]) -> PreparationResult {
    guard let last = statuses.last else { return .noChange }
    switch last {
    case .committedFreshInstall:
      return .installed
    case .committedReplacement:
      return .replaced
    case .recoveredKeepingCanonical, .recoveredFreshInstall, .recoveredPriorPackage:
      return .recovered
    case .noChange, .needsReinventory:
      return .noChange
    }
  }

  private func keepBothOwnersDisabled() {
    disableBeforeStaticLoad([expected.identifier, Self.communityIdentifier])
    let hasEnabledOwner = JavascriptPlugin.plugins.contains { plugin in
      (plugin.identifier == expected.identifier || plugin.identifier == Self.communityIdentifier) && plugin.enabled
    }
    guard hasEnabledOwner else { return }
    PlayerCore.playerCores.forEach { $0.clearPlugins() }
    JavascriptPlugin.recreateAllPlugins()
    JavascriptPlugin.loadGlobalInstances()
    PlayerCore.playerCores.forEach { $0.loadPlugins() }
  }

  private func verifyAcceptedStaticInventory() throws {
    let forks = JavascriptPlugin.plugins.filter { $0.identifier == expected.identifier }
    guard forks.count == 1, forks[0].enabled else {
      throw BundledPluginCoreError.transactionFailed(
        "accepted resolution did not produce exactly one enabled fork owner"
      )
    }
    let communities = JavascriptPlugin.plugins.filter { $0.identifier == Self.communityIdentifier }
    guard communities.allSatisfy({ !$0.enabled }) else {
      throw BundledPluginCoreError.transactionFailed(
        "accepted resolution left the community owner enabled"
      )
    }
  }

  private func accept(_ pending: PendingResolution) {
    do {
      let assets = try loadTrustedAssets()
      let inventory = try makeRawInventory(
        catalog: assets.catalog,
        trustedCatalogs: assets.trustedCatalogs
      )
      switch pending.kind {
      case .communityMigration:
        let imported = try readCommunityPreferences()
        guard inventory.forkPackages.allSatisfy({ $0.marker != nil }) else {
          throw BundledPluginCoreError.transactionFailed("an unmanaged fork package must be resolved before community migration")
        }
        let withoutCommunity = BundledPluginInventory(
          forkPackages: inventory.forkPackages,
          communityPackages: [],
          storedEnabled: inventory.storedEnabled,
          storedOrder: inventory.storedOrder
        )
        let decision = BundledPluginPolicy.evaluate(catalog: assets.catalog, inventory: withoutCommunity)
        try executeAcceptedDecision(decision, assets: assets, inventory: withoutCommunity)
        try writeImportedPreferences(imported)
      case .unmanagedReplacement:
        guard inventory.forkPackages.count == 1,
              let directoryName = inventory.forkPackages.first?.directoryName else {
          throw BundledPluginCoreError.transactionFailed("unmanaged replacement requires exactly one fork package")
        }
        try preserveUnmanagedAndInstall(
          directoryName: directoryName,
          assets: assets,
          inventory: inventory
        )
      case .multipleOwners:
        keepBothOwnersDisabled()
        return
      }

      defaults.set(false, forKey: enabledDefaultsKey(Self.communityIdentifier))
      defaults.set(true, forKey: enabledDefaultsKey(expected.identifier))
      refreshStaticInventoryAfterAcceptedResolution()
      try verifyAcceptedStaticInventory()
      if pending.kind == .communityMigration {
        defaults.set(true, forKey: Self.communityMigrationAcceptedDefaultsKey)
      }
      pendingResolution = nil
      preparationResult = .noChange
    } catch {
      keepBothOwnersDisabled()
      // Keep the structured conflict available for a later retry. A failed
      // import/transaction still leaves both owners disabled, but it must not
      // silently turn an unresolved conflict into a terminal state.
      resolutionPresented = false
      resolutionInventoryRefreshed = false
      preparationResult = .failed(error.localizedDescription)
      Logger.log("Bundled Anime4K resolution failed: \(error.localizedDescription)", level: .error)
    }
  }

  private func executeAcceptedDecision(
    _ decision: BundledPluginDecision,
    assets: TrustedAssets,
    inventory: BundledPluginInventory
  ) throws {
    let transaction = try makeTransaction(
      assets: assets,
      adapterState: .init(enabled: inventory.storedEnabled, order: inventory.storedOrder)
    )
    let outcome: BundledPluginTransactionOutcome
    switch decision.action {
    case .install:
      outcome = try transaction.installFresh(archiveData: assets.archiveData)
    case .upgrade, .repair:
      outcome = try transaction.replace(archiveData: assets.archiveData)
    case .noOp:
      return
    case .requireUnmanagedReplacement, .requireCommunityMigration, .resolveMultipleOwners:
      throw BundledPluginCoreError.transactionFailed("accepted resolution produced another unresolved conflict")
    }
    guard outcome.status != .needsReinventory else {
      throw BundledPluginCoreError.transactionFailed("filesystem changed during accepted resolution")
    }
  }

  private func preserveUnmanagedAndInstall(
    directoryName: String,
    assets: TrustedAssets,
    inventory: BundledPluginInventory
  ) throws {
    let root = Utility.pluginsURL
    let original = root.appendingPathComponent(directoryName, isDirectory: true)
    let backup = root.appendingPathComponent(
      ".io.iina.magnet.anime4k.unmanaged-\(UUID().uuidString)",
      isDirectory: true
    )
    try renamer.renameExclusive(from: original, to: backup)
    do {
      let transaction = try makeTransaction(
        assets: assets,
        adapterState: .init(enabled: inventory.storedEnabled, order: inventory.storedOrder)
      )
      let outcome = try transaction.installFresh(archiveData: assets.archiveData)
      guard outcome.status == .committedFreshInstall || outcome.status == .recoveredFreshInstall else {
        throw BundledPluginCoreError.transactionFailed("managed replacement did not commit")
      }
    } catch {
      if !fileSystem.itemExists(at: original) {
        try? renamer.renameExclusive(from: backup, to: original)
      }
      throw error
    }
  }

  private func readCommunityPreferences() throws -> [String: Any] {
    let url = Utility.pluginsURL
      .appendingPathComponent(".preferences", isDirectory: true)
      .appendingPathComponent("\(Self.communityIdentifier).plist", isDirectory: false)
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
      throw BundledPluginCoreError.transactionFailed("community preferences are not a property-list dictionary")
    }
    var imported: [String: Any] = [:]
    if let value = dictionary["mode"] {
      guard let mode = value as? String,
            ["off", "A", "B", "C", "A+A", "B+B", "C+A"].contains(mode) else {
        throw BundledPluginCoreError.transactionFailed("community mode is unsupported")
      }
      imported["mode"] = mode
    }
    if let value = dictionary["quality"] {
      guard let quality = value as? String, ["fast", "hq"].contains(quality) else {
        throw BundledPluginCoreError.transactionFailed("community quality is unsupported")
      }
      imported["quality"] = quality
    }
    if let value = dictionary["autoApply"] {
      guard let autoApply = value as? Bool else {
        throw BundledPluginCoreError.transactionFailed("community autoApply is unsupported")
      }
      imported["autoApply"] = autoApply
    }
    return imported
  }

  private func writeImportedPreferences(_ imported: [String: Any]) throws {
    guard !imported.isEmpty else { return }
    let directory = Utility.pluginsURL.appendingPathComponent(".preferences", isDirectory: true)
    let url = directory.appendingPathComponent("\(expected.identifier).plist", isDirectory: false)
    var merged: [String: Any] = [:]
    if FileManager.default.fileExists(atPath: url.path) {
      let current = try Data(contentsOf: url, options: [.mappedIfSafe])
      guard let dictionary = try PropertyListSerialization.propertyList(from: current, format: nil) as? [String: Any] else {
        throw BundledPluginCoreError.transactionFailed("fork preferences are not a property-list dictionary")
      }
      merged = dictionary
    }
    imported.forEach { merged[$0.key] = $0.value }
    let data = try PropertyListSerialization.data(fromPropertyList: merged, format: .binary, options: 0)
    try fileSystem.writeDataAtomicallyAndSync(data, to: url)
  }

  private func refreshStaticInventoryAfterAcceptedResolution() {
    guard !resolutionInventoryRefreshed else { return }
    resolutionInventoryRefreshed = true
    // Release menu-owned instances while their weak plugin descriptors are
    // still valid. Then replace the inventory as one ordered batch and rebuild
    // derived UI only after every player has its complete new plugin set.
    AppDelegate.shared.menuController?.preparePluginMenuForReload()
    PlayerCore.playerCores.forEach { $0.clearPlugins() }
    JavascriptPlugin.recreateAllPlugins()
    JavascriptPlugin.loadGlobalInstances()
    PlayerCore.playerCores.forEach { $0.loadPlugins() }
    AppDelegate.shared.menuController?.updatePluginMenu()
  }
}

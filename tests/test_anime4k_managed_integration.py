import re
from pathlib import Path
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
MANAGER = REPOSITORY / "iina" / "BundledPluginManager.swift"
APP_DELEGATE = REPOSITORY / "iina" / "AppDelegate.swift"
PROJECT = REPOSITORY / "iina.xcodeproj" / "project.pbxproj"
MENU_CONTROLLER = REPOSITORY / "iina" / "MenuController.swift"
PLUGIN_INSTANCE = REPOSITORY / "iina" / "JavascriptPluginInstance.swift"
SIDEBAR_API = REPOSITORY / "iina" / "JavascriptAPISidebarView.swift"
PLAYER_CORE = REPOSITORY / "iina" / "PlayerCore.swift"
MENU_API = REPOSITORY / "iina" / "JavascriptAPIMenu.swift"
TRANSACTION = (
    REPOSITORY
    / "iina-magnet"
    / "Sources"
    / "IinaMagnet"
    / "Anime4K"
    / "BundledPluginTransaction.swift"
)


def function_body(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"unterminated function: {signature}")


class Anime4KManagedIntegrationSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manager = MANAGER.read_text(encoding="utf-8")
        cls.app = APP_DELEGATE.read_text(encoding="utf-8")
        cls.project = PROJECT.read_text(encoding="utf-8")
        cls.menu = MENU_CONTROLLER.read_text(encoding="utf-8")
        cls.plugin_instance = PLUGIN_INSTANCE.read_text(encoding="utf-8")
        cls.sidebar_api = SIDEBAR_API.read_text(encoding="utf-8")
        cls.player_core = PLAYER_CORE.read_text(encoding="utf-8")
        cls.menu_api = MENU_API.read_text(encoding="utf-8")
        cls.transaction = TRANSACTION.read_text(encoding="utf-8")

    def test_prepare_precedes_static_plugin_inventory_and_player_creation(self):
        will_finish = function_body(
            self.app,
            "func applicationWillFinishLaunching(_ notification: Notification)",
        )
        prepare = will_finish.index("BundledPluginManager.shared.prepare()")
        first_inventory = will_finish.index("JavascriptPlugin.plugins")
        self.assertLess(prepare, first_inventory)
        self.assertNotIn("PlayerCore.", will_finish[:prepare])
        manager_prepare = function_body(self.manager, "func prepare()")
        self.assertNotIn("PlayerCore", manager_prepare)

    def test_post_ready_resolution_is_nonblocking(self):
        did_finish = function_body(
            self.app,
            "func applicationDidFinishLaunching(_ aNotification: Notification)",
        )
        self.assertLess(
            did_finish.index("getReady()"),
            did_finish.index("BundledPluginManager.shared.presentPendingResolution()"),
        )
        present = function_body(self.manager, "func presentPendingResolution()")
        retry = function_body(self.manager, "private func present(")
        self.assertIn("remainingWindowAttempts: 20", present)
        self.assertIn("DispatchQueue.main.asyncAfter", retry)
        self.assertIn("remainingWindowAttempts - 1", retry)
        self.assertIn("beginSheetModal", retry)
        self.assertNotIn("runModal", retry)
        self.assertIn("no presentation window became ready", retry)

    def test_plugin_menu_refresh_is_safe_before_outlets_are_bound(self):
        refresh = function_body(self.menu, "func updatePluginMenu(")
        self.assertIn("guard pluginMenu != nil else { return }", refresh)

    def test_managed_archive_is_skipped_before_legacy_create(self):
        will_finish = function_body(
            self.app,
            "func applicationWillFinishLaunching(_ notification: Notification)",
        )
        skip = will_finish.index("!BundledPluginManager.managesBundledArchive")
        create = will_finish.index("JavascriptPlugin.create(fromPackageURL:")
        self.assertLess(skip, create)
        self.assertIn('archiveFileName: "anime4k.iinaplgz"', (
            REPOSITORY
            / "iina-magnet/Sources/IinaMagnet/Anime4K/BundledPluginModels.swift"
        ).read_text(encoding="utf-8"))

    def test_manager_uses_trusted_assets_policy_and_transaction(self):
        for required in (
            "Bundle.main.resourceURL",
            "BundledPluginTrustedVerifier.decodeCatalog",
            "BundledPluginTrustedVerifier.verifyCatalog",
            "BundledPluginTrustedVerifier.decodeTrustHistory",
            "BundledPluginTrustedVerifier.verifyTrustHistory",
            "BundledPluginCatalogSetPackageValidator",
            "BundledPluginPolicy.evaluate",
            "transaction.recover()",
            "transaction.installFresh",
            "transaction.replace",
        ):
            self.assertIn(required, self.manager)
        self.assertNotRegex(self.manager, r"Process\s*\(")
        self.assertNotRegex(self.manager, r"/bin/(?:sh|bash|zsh)")
        self.assertNotIn("BundledPluginTrustedVerifier.verifyManagedPackage", self.manager)
        load_assets = function_body(self.manager, "private func loadTrustedAssets()")
        self.assertIn("Bundle.main.resourceURL", load_assets)
        self.assertIn("trustHistoryFileName", load_assets)
        self.assertNotIn("Utility.pluginsURL", load_assets)

    def test_final_policy_restores_only_missing_enabled_default_after_restart(self):
        prepare = function_body(self.manager, "func prepare()")
        final_policy = prepare.rindex("BundledPluginPolicy.evaluate")
        final_enable = prepare.rindex("if decision.shouldEnableFreshShell")
        static_load = prepare.index("loadFinalStaticInventoryOnce()")
        self.assertLess(final_policy, final_enable)
        self.assertLess(final_enable, static_load)
        self.assertNotIn("if let outcome", prepare[final_enable - 80:final_enable])

    def test_archive_extractor_is_argument_based_and_validated(self):
        self.assertIn('process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")', self.transaction)
        self.assertIn('process.arguments = ["-x", "-k", archiveURL.path, destination.path]', self.transaction)
        self.assertIn("BundledPluginTrustedVerifier.validateArchiveEntries(entries)", self.transaction)
        self.assertIn('stagingName: String = ".io.iina.magnet.anime4k.stage"', self.transaction)
        self.assertNotRegex(self.transaction, r"/bin/(?:sh|bash|zsh)")

    def test_malformed_canonical_is_inventory_conflict_not_absent(self):
        inventory = function_body(self.manager, "private func makeRawInventory(")
        self.assertIn("if isCanonicalName", inventory)
        self.assertRegex(
            inventory,
            r"if isCanonicalName\s*\{[\s\S]*?marker: nil,[\s\S]*?isHealthy: false",
        )
        self.assertIn("raw.identifier == catalog.identifier || isCanonicalName", inventory)

    def test_direct_defaults_fail_off_and_fresh_enable_are_separate(self):
        prepare = function_body(self.manager, "func prepare()")
        self.assertIn("disableBeforeStaticLoad(decision.disableIdentifiers)", prepare)
        self.assertIn("if decision.shouldEnableFreshShell", prepare)
        self.assertIn("defaults.set(true", prepare)
        self.assertIn("disableBeforeStaticLoad([expected.identifier, Self.communityIdentifier])", prepare)
        self.assertNotIn("PluginOrder\"", prepare)
        self.assertNotRegex(self.manager, r'removeItem[\s\S]{0,120}"\.data"')

    def test_success_initializes_final_static_inventory_once_and_failure_does_not(self):
        prepare = function_body(self.manager, "func prepare()")
        self.assertEqual(prepare.count("loadFinalStaticInventoryOnce()"), 1)
        self.assertIn("if !successfulStatuses.isEmpty", prepare)
        final_load = function_body(self.manager, "private func loadFinalStaticInventoryOnce()")
        self.assertIn("guard !loadedStaticInventory", final_load)
        self.assertEqual(final_load.count("JavascriptPlugin.plugins"), 1)
        self.assertNotIn("recreateAllPlugins", final_load)

    def test_real_resolution_ui_has_accept_cancel_and_safe_failure_paths(self):
        present = function_body(self.manager, "private func present(")
        self.assertIn('addButton(withTitle: "Migrate")', present)
        self.assertIn('addButton(withTitle: "Replace")', present)
        self.assertGreaterEqual(present.count('addButton(withTitle: "Cancel")'), 2)
        self.assertIn("keepBothOwnersDisabled()", present)
        cancel_branch = present.split("guard response == .alertFirstButtonReturn else", 1)[1]
        self.assertNotIn("pendingResolution = nil", cancel_branch.split("self.accept", 1)[0])
        accept = function_body(self.manager, "private func accept(")
        self.assertIn("readCommunityPreferences()", accept)
        self.assertIn("writeImportedPreferences(imported)", accept)
        self.assertIn("preserveUnmanagedAndInstall", accept)
        self.assertIn("keepBothOwnersDisabled()", accept)
        self.assertIn("defaults.set(false", accept)
        self.assertIn("defaults.set(true", accept)
        failure = accept.rsplit("} catch {", 1)[1]
        self.assertIn("resolutionPresented = false", failure)
        self.assertNotIn("pendingResolution = nil", failure)

    def test_community_is_never_deleted_and_unmanaged_is_hidden_before_install(self):
        preserve = function_body(self.manager, "private func preserveUnmanagedAndInstall(")
        self.assertIn(".io.iina.magnet.anime4k.unmanaged-", preserve)
        self.assertIn("renamer.renameExclusive(from: original, to: backup)", preserve)
        self.assertIn("renamer.renameExclusive(from: backup, to: original)", preserve)
        self.assertNotIn("removeItem", preserve)
        self.assertNotRegex(self.manager, r"removeItem[\s\S]{0,160}community")

    def test_accepted_resolution_refreshes_static_inventory_at_most_once(self):
        refresh = function_body(
            self.manager,
            "private func refreshStaticInventoryAfterAcceptedResolution()",
        )
        self.assertIn("guard !resolutionInventoryRefreshed", refresh)
        self.assertEqual(refresh.count("JavascriptPlugin.recreateAllPlugins()"), 1)

    def test_accepted_community_migration_persists_a_durable_marker(self):
        self.assertIn("communityMigrationAcceptedDefaultsKey", self.manager)
        accept = function_body(self.manager, "private func accept(")
        refresh = accept.index("refreshStaticInventoryAfterAcceptedResolution()")
        verify = accept.index("try verifyAcceptedStaticInventory()")
        persist = accept.index(
            "defaults.set(true, forKey: Self.communityMigrationAcceptedDefaultsKey)"
        )
        clear_pending = accept.index("pendingResolution = nil")
        self.assertLess(refresh, verify)
        self.assertLess(verify, persist)
        self.assertLess(persist, clear_pending)

    def test_accepted_disabled_community_is_suppressed_until_reenabled(self):
        prepare = function_body(self.manager, "func prepare()")
        self.assertIn("makePolicyInventory", prepare)
        self.assertEqual(
            prepare.count("makePolicyInventory"),
            prepare.count("makeRawInventory"),
        )
        policy_inventory = function_body(
            self.manager,
            "private func makePolicyInventory(",
        )
        self.assertIn("communityMigrationAcceptedDefaultsKey", policy_inventory)
        self.assertIn("inventory.communityPackages.isEmpty", policy_inventory)
        self.assertIn(
            "defaults.bool(forKey: enabledDefaultsKey(Self.communityIdentifier))",
            policy_inventory,
        )
        self.assertIn(
            "defaults.removeObject(forKey: Self.communityMigrationAcceptedDefaultsKey)",
            policy_inventory,
        )
        self.assertIn("communityPackages: []", policy_inventory)
        self.assertIn("disableBeforeStaticLoad([Self.communityIdentifier])", policy_inventory)

    def test_accepted_refresh_is_ordered_batch_reload_without_enabled_setters(self):
        accept = function_body(self.manager, "private func accept(")
        self.assertNotRegex(accept, r"\.enabled\s*=")

        refresh = function_body(
            self.manager,
            "private func refreshStaticInventoryAfterAcceptedResolution()",
        )
        ordered = [
            "AppDelegate.shared.menuController?.preparePluginMenuForReload()",
            "PlayerCore.playerCores.forEach { $0.clearPlugins() }",
            "JavascriptPlugin.recreateAllPlugins()",
            "JavascriptPlugin.loadGlobalInstances()",
            "PlayerCore.playerCores.forEach { $0.loadPlugins() }",
            "AppDelegate.shared.menuController?.updatePluginMenu()",
        ]
        positions = [refresh.index(statement) for statement in ordered]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("reloadPluginForAll", refresh)
        self.assertNotIn("withExtendedLifetime", refresh)

        fail_off = function_body(self.manager, "private func keepBothOwnersDisabled()")
        self.assertNotRegex(fail_off, r"\.enabled\s*=")
        self.assertIn("guard hasEnabledOwner else { return }", fail_off)
        self.assertNotIn("reloadPluginForAll", fail_off)
        self.assertNotIn("updatePluginMenu", fail_off)

        verify = function_body(
            self.manager,
            "private func verifyAcceptedStaticInventory(",
        )
        self.assertIn("forks.count == 1", verify)
        self.assertIn("forks[0].enabled", verify)
        self.assertIn("communities.allSatisfy", verify)
        self.assertNotRegex(verify, r"\.enabled\s*=")

    def test_retired_plugin_cleanup_does_not_force_unwrap_recreated_descriptor(self):
        self.assertIn("let identifier: String", self.plugin_instance)
        initializer = function_body(
            self.plugin_instance,
            "init(player: PlayerCore?, plugin: JavascriptPlugin)",
        )
        self.assertIn("identifier = plugin.identifier", initializer)

        cleanup = function_body(self.sidebar_api, "override func cleanUp(")
        self.assertIn("guard let player else { return }", cleanup)
        self.assertIn("instance.identifier", cleanup)
        self.assertNotIn("instance.plugin.identifier", cleanup)

    def test_plugin_menu_releases_retired_instances_before_static_recreation(self):
        prepare = function_body(self.menu, "func preparePluginMenuForReload()")
        self.assertIn("representedObject is JavascriptPluginInstance", prepare)
        self.assertIn("item.representedObject = nil", prepare)
        self.assertIn("releasePluginInstances", prepare)
        self.assertIn("pluginMenu.removeAllItems()", prepare)

        reload_all = function_body(self.app, "@objc func reloadAllPlugins(")
        self.assertIn("menuController.preparePluginMenuForReload()", reload_all)
        self.assertNotIn("representedObject = nil", reload_all)

        load_plugins = function_body(self.player_core, "func loadPlugins()")
        self.assertGreater(
            load_plugins.index("mainWindow.pluginView.updatePluginTabs()"),
            load_plugins.index("plugins = JavascriptPlugin.plugins.compactMap"),
        )
        self.assertGreater(
            load_plugins.index("requestPluginMenuUpdate()"),
            load_plugins.index("plugins = JavascriptPlugin.plugins.compactMap"),
        )

    def test_plugin_menu_force_update_never_reenters_first_player_initialization(self):
        force_update = function_body(self.menu_api, "  func forceUpdate() {")
        self.assertIn("requestPluginMenuUpdate()", force_update)
        self.assertNotIn("Utility.executeOnMainThread", force_update)

        request = function_body(self.menu, "func requestPluginMenuUpdate()")
        self.assertIn("DispatchQueue.main.async", request)
        self.assertIn("self?.updatePluginMenu()", request)

        refresh = function_body(self.menu, "func updatePluginMenu()")
        self.assertIn("PlayerCore.active.plugins", refresh)

    def test_manager_is_in_main_target_sources_exactly_once(self):
        self.assertEqual(
            self.project.count("BundledPluginManager.swift in Sources"),
            2,
            "one PBXBuildFile declaration and one Sources membership are required",
        )
        self.assertEqual(self.project.count("BundledPluginManager.swift */"), 3)
        source_phase = re.search(
            r"84EB1ED21D2F51D3004FA5A1 /\* Sources \*/ = \{[\s\S]*?\n\t\t\};",
            self.project,
        )
        self.assertIsNotNone(source_phase)
        self.assertIn("BundledPluginManager.swift in Sources", source_phase.group(0))


if __name__ == "__main__":
    unittest.main()

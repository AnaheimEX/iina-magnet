import importlib.util
import io
import json
from pathlib import Path
import shutil
import stat
import tempfile
import unittest
import warnings
import zipfile


REPOSITORY = Path(__file__).resolve().parents[1]
BUILDER_PATH = REPOSITORY / "scripts" / "build-anime4k-plugin.py"
SPEC = importlib.util.spec_from_file_location("anime4k_builder", BUILDER_PATH)
builder = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(builder)


class Anime4KPluginPackageTests(unittest.TestCase):
    source = REPOSITORY / "deps" / "plugins-src" / "anime4k"
    archive = REPOSITORY / "deps" / "plugins" / "anime4k.iinaplgz"
    catalog = REPOSITORY / "deps" / "plugins" / "anime4k.catalog.json"
    history_sources = REPOSITORY / "deps" / "plugins-src" / "anime4k" / "trusted-catalogs"
    trust_history = REPOSITORY / "deps" / "plugins" / "anime4k.trusted-catalogs.json"

    def copy_source(self, root: Path) -> Path:
        destination = root / "anime4k"
        shutil.copytree(self.source, destination)
        return destination

    def generated_fixture(self, root: Path):
        source = self.copy_source(root)
        bundle, archive, catalog = builder.build_artifacts(source)
        archive_path = root / "anime4k.iinaplgz"
        catalog_path = root / "anime4k.catalog.json"
        builder.write_atomic(source / "lib" / "shader-bundle.js", bundle)
        builder.write_atomic(archive_path, archive)
        builder.write_atomic(catalog_path, catalog)
        builder.write_atomic(
            root / "anime4k.trusted-catalogs.json",
            builder.render_trust_history(source / "trusted-catalogs", catalog),
        )
        return source, archive_path, catalog_path

    @staticmethod
    def zip_with(entries, *, timestamp=builder.ZIP_TIMESTAMP, mode=builder.FILE_MODE,
                 compression=zipfile.ZIP_STORED, create_system=3):
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w") as archive:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                for name, data in entries:
                    info = zipfile.ZipInfo(name, timestamp)
                    info.compress_type = compression
                    info.create_system = create_system
                    info.external_attr = mode << 16
                    archive.writestr(info, data)
        return output.getvalue()

    def test_two_independent_builds_are_byte_identical(self):
        first = builder.build_artifacts(self.source)
        second = builder.build_artifacts(self.source)
        self.assertEqual(first, second)
        self.assertEqual(builder.sha256(first[1]), builder.sha256(second[1]))
        self.assertEqual(json.loads(first[2])["entries"], json.loads(second[2])["entries"])

    def test_check_mode_is_read_only_and_current(self):
        paths = [self.source / "lib" / "shader-bundle.js", self.archive, self.catalog, self.trust_history]
        before = [(path.read_bytes(), path.stat().st_mtime_ns) for path in paths]
        builder.check_artifacts(
            self.source, self.archive, self.catalog,
            self.history_sources, self.trust_history,
        )
        after = [(path.read_bytes(), path.stat().st_mtime_ns) for path in paths]
        self.assertEqual(before, after)

    def test_trust_history_is_deterministic_and_retains_exact_versioned_catalogs(self):
        source_catalog = self.history_sources / f"{builder.EXPECTED_VERSION}.catalog.json"
        self.assertEqual(source_catalog.read_bytes(), self.catalog.read_bytes())
        first = builder.render_trust_history(self.history_sources, self.catalog.read_bytes())
        second = builder.render_trust_history(self.history_sources, self.catalog.read_bytes())
        self.assertEqual(first, second)
        self.assertEqual(first, self.trust_history.read_bytes())
        value = json.loads(first)
        self.assertEqual(value["schemaVersion"], 1)
        self.assertEqual(value["identifier"], builder.EXPECTED_IDENTIFIER)
        self.assertEqual(value["packageSchemaVersion"], builder.EXPECTED_PACKAGE_SCHEMA)
        self.assertEqual(
            [catalog["version"] for catalog in value["catalogs"]],
            ["1.0.0", "1.0.1", builder.EXPECTED_VERSION],
        )

    def test_trust_history_rejects_tamper_duplicates_and_missing_source_catalogs(self):
        current = self.catalog.read_bytes()
        with tempfile.TemporaryDirectory() as temporary:
            history = Path(temporary)
            (history / f"{builder.EXPECTED_VERSION}.catalog.json").write_bytes(current)
            bad = json.loads(current)
            bad["entries"] = []
            (history / "2.0.0.catalog.json").write_text(json.dumps(bad))
            with self.assertRaisesRegex(builder.BuildError, "historical catalog"):
                builder.render_trust_history(history, current)
        with tempfile.TemporaryDirectory() as temporary:
            history = Path(temporary)
            with self.assertRaisesRegex(builder.BuildError, "historical catalog"):
                builder.render_trust_history(history, current)

    def test_future_version_requires_a_new_retained_source_without_overwriting_current(self):
        current = self.catalog.read_bytes()
        v2_value = json.loads(current)
        v2_value["version"] = "2.0.0"
        v2_value["archive"]["sha256"] = "sha256:" + "2" * 64
        v2 = (json.dumps(v2_value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()
        with tempfile.TemporaryDirectory() as temporary:
            history = Path(temporary)
            current_source = history / f"{builder.EXPECTED_VERSION}.catalog.json"
            current_source.write_bytes(current)
            with self.assertRaisesRegex(builder.BuildError, "must be retained"):
                builder.render_trust_history(history, v2)
            (history / "2.0.0.catalog.json").write_bytes(v2)
            catalogs = json.loads(builder.render_trust_history(history, v2))["catalogs"]
            self.assertEqual(
                [catalog["version"] for catalog in catalogs],
                [builder.EXPECTED_VERSION, "2.0.0"],
            )
            self.assertEqual(current_source.read_bytes(), current)
    def test_shader_tamper_missing_and_extra_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.copy_source(root)
            shader = source / "shaders" / "Anime4K_Clamp_Highlights.glsl"
            shader.write_bytes(shader.read_bytes() + b"\n")
            with self.assertRaisesRegex(builder.BuildError, "shader integrity mismatch"):
                builder.build_artifacts(source)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.copy_source(root)
            (source / "shaders" / "Anime4K_Clamp_Highlights.glsl").unlink()
            with self.assertRaisesRegex(builder.BuildError, "allow-list mismatch"):
                builder.build_artifacts(source)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.copy_source(root)
            (source / "shaders" / "unexpected.glsl").write_text("//!HOOK MAIN\n")
            with self.assertRaisesRegex(builder.BuildError, "allow-list mismatch"):
                builder.build_artifacts(source)

    def test_manifest_pin_preset_and_shader_record_drift_are_rejected(self):
        mutations = [
            lambda value: value["upstream"].update(commit="0" * 40),
            lambda value: value["presets"]["fast"]["A"].reverse(),
            lambda value: value["shaders"][0].update(size=1),
        ]
        for mutate in mutations:
            with self.subTest(mutate=mutate), tempfile.TemporaryDirectory() as temporary:
                source = self.copy_source(Path(temporary))
                path = source / "manifest.json"
                value = json.loads(path.read_text())
                mutate(value)
                path.write_text(json.dumps(value), encoding="utf-8")
                with self.assertRaises(builder.BuildError):
                    builder.build_artifacts(source)

    def test_managed_digest_and_license_drift_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = self.copy_source(Path(temporary))
            info_path = source / "Info.json"
            info = json.loads(info_path.read_text())
            info["iinaMagnetManaged"]["contentManifestDigest"] = "sha256:" + "0" * 64
            info_path.write_text(json.dumps(info), encoding="utf-8")
            with self.assertRaisesRegex(builder.BuildError, "managed marker"):
                builder.build_artifacts(source)
        with tempfile.TemporaryDirectory() as temporary:
            source = self.copy_source(Path(temporary))
            (source / "licenses" / "Anime4K-LICENSE.txt").write_text("MIT\n")
            with self.assertRaisesRegex(builder.BuildError, "license drifted"):
                builder.build_artifacts(source)
        for relative in builder.EXPECTED_LICENSE_HASHES:
            with self.subTest(missing=relative), tempfile.TemporaryDirectory() as temporary:
                source = self.copy_source(Path(temporary))
                (source / relative).unlink()
                with self.assertRaisesRegex(builder.BuildError, "cannot read required file"):
                    builder.build_artifacts(source)

    def test_wrong_package_identifier_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = self.copy_source(Path(temporary))
            info_path = source / "Info.json"
            info = json.loads(info_path.read_text())
            info["identifier"] = "example.invalid"
            info_path.write_text(json.dumps(info))
            with self.assertRaisesRegex(builder.BuildError, "identifier/version"):
                builder.build_artifacts(source)

    def test_runtime_state_defaults_and_commonjs_modules_are_packaged(self):
        bundle, _archive, _catalog = builder.build_artifacts(self.source)
        entries = builder.package_entries(self.source, bundle)
        expected_modules = {
            "lib/integrity.js", "lib/reconcile.js", "lib/runtime.js",
            "lib/sha256.js", "lib/shortcuts.js", "lib/state.js", "lib/telemetry.js",
        }
        self.assertTrue(expected_modules.issubset(entries))
        info = json.loads(entries["Info.json"])
        defaults = info["preferenceDefaults"]
        self.assertEqual(defaults["mode"], "off")
        self.assertEqual(defaults["quality"], "fast")
        self.assertEqual(defaults["lastMode"], "A")
        self.assertEqual(defaults["lastQuality"], "fast")
        self.assertEqual(defaults["shaderBundleVersion"], 1)
        self.assertEqual(defaults["shortcuts"], {
            "off": "Ctrl+0", "A": "Ctrl+1", "B": "Ctrl+2", "C": "Ctrl+3",
            "A+A": "Ctrl+4", "B+B": "Ctrl+5", "C+A": "Ctrl+6",
            "fast": "Ctrl+7", "hq": "Ctrl+8",
        })
        self.assertEqual(info["sidebarTab"], {"name": "Anime4K"})
        runtime_text = entries["lib/runtime.js"].decode("utf-8")
        self.assertIn("setInterval", runtime_text)
        self.assertIn("clearInterval", runtime_text)
        self.assertNotIn("setTimeout", runtime_text)
        for path in expected_modules:
            text = entries[path].decode("utf-8")
            self.assertIn('"use strict";', text)
            self.assertNotRegex(text, r"require\s*\(\s*[\"'](?:node:|fs|crypto|path|os)")

    def test_runtime_network_dependency_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = self.copy_source(Path(temporary))
            (source / "ui" / "sidebar.js").write_text('fetch("https://example.invalid/shader")\n')
            with self.assertRaisesRegex(builder.BuildError, "runtime network"):
                builder.build_artifacts(source)

    def test_network_scan_allows_only_exact_pinned_unlicense_comments(self):
        bundle, _archive, _catalog = builder.build_artifacts(self.source)
        entries = builder.package_entries(self.source, bundle)
        builder.validate_packaged_runtime_network_surface(entries)

        info = json.loads(entries["Info.json"])
        self.assertEqual(info["permissions"], ["show-osd"])
        manifest = json.loads(entries["manifest.json"])
        by_license = {}
        for shader in manifest["shaders"]:
            by_license.setdefault(shader["license"], []).append(shader["id"])
        self.assertEqual(len(by_license["MIT"]), 12)
        self.assertEqual(set(by_license["Unlicense"]), builder.UNLICENSE_SHADER_IDS)

        runtime_urls = {}
        for name, data in entries.items():
            if builder.is_packaged_runtime_path(name):
                urls = builder.NETWORK_URL_PATTERN.findall(data.decode("utf-8"))
                if urls:
                    runtime_urls[name] = urls
        self.assertEqual(runtime_urls, {
            "lib/shader-bundle.js": [builder.UNLICENSE_URL, builder.UNLICENSE_URL],
            "shaders/Anime4K_AutoDownscalePre_x2.glsl": [builder.UNLICENSE_URL],
            "shaders/Anime4K_AutoDownscalePre_x4.glsl": [builder.UNLICENSE_URL],
        })
        # Legal documents are not executable runtime; their informational URLs
        # do not create a network surface and are deliberately outside the
        # runtime allow-list above.
        self.assertIn(b"http://fsf.org/", entries["LICENSE"])

        mutations = {}
        mutations["same URL in main"] = dict(entries)
        mutations["same URL in main"]["main.js"] += (builder.UNLICENSE_COMMENT + "\n").encode()
        mutations["same URL in MIT shader"] = dict(entries)
        mutations["same URL in MIT shader"]["shaders/Anime4K_Clamp_Highlights.glsl"] += (
            builder.UNLICENSE_COMMENT + "\n"
        ).encode()
        mutations["duplicate URL in allowed shader"] = dict(entries)
        mutations["duplicate URL in allowed shader"]["shaders/Anime4K_AutoDownscalePre_x2.glsl"] += (
            builder.UNLICENSE_COMMENT + "\n"
        ).encode()
        mutations["different URL in bundle"] = dict(entries)
        mutations["different URL in bundle"]["lib/shader-bundle.js"] = bundle.replace(
            builder.UNLICENSE_URL.encode(), b"https://example.invalid", 1
        )
        mutations["relative fetch capability"] = dict(entries)
        mutations["relative fetch capability"]["ui/sidebar.js"] += b'\nfetch("/shader")\n'
        mutations["IINA HTTP capability"] = dict(entries)
        mutations["IINA HTTP capability"]["main.js"] += b'\niina.http.get("/shader")\n'
        mutations["IINA WebSocket capability"] = dict(entries)
        mutations["IINA WebSocket capability"]["main.js"] += b'\niina["ws"].startServer()\n'
        for label, mutated in mutations.items():
            with self.subTest(label=label), self.assertRaisesRegex(builder.BuildError, "network|allowance"):
                builder.validate_packaged_runtime_network_surface(mutated)

    def test_stale_bundle_archive_and_catalog_are_rejected(self):
        for target in ("bundle", "archive", "catalog"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temporary:
                source, archive_path, catalog_path = self.generated_fixture(Path(temporary))
                if target == "bundle":
                    (source / "lib" / "shader-bundle.js").write_bytes(b'"use strict";\n')
                elif target == "archive":
                    archive_path.write_bytes(archive_path.read_bytes() + b"stale")
                else:
                    value = json.loads(catalog_path.read_text())
                    value["archive"]["sha256"] = "sha256:" + "0" * 64
                    catalog_path.write_text(json.dumps(value))
                with self.assertRaises(builder.BuildError):
                    builder.check_artifacts(source, archive_path, catalog_path)

    def test_runtime_bundle_manifest_drift_and_extra_archive_entry_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, archive_path, catalog_path = self.generated_fixture(Path(temporary))
            bundle_path = source / "lib" / "shader-bundle.js"
            payload = builder.decode_bundle(bundle_path.read_bytes())
            payload["manifest"]["plugin"]["identifier"] = "example.invalid"
            encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2, separators=(",", ": ")).encode()
            bundle_path.write_bytes(builder.BUNDLE_PREFIX + encoded + builder.BUNDLE_SUFFIX)
            with self.assertRaisesRegex(builder.BuildError, "bundle payload"):
                builder.check_artifacts(source, archive_path, catalog_path)

        bundle, archive, _catalog = builder.build_artifacts(self.source)
        entries = builder.package_entries(self.source, bundle)
        mutated = io.BytesIO(archive)
        with zipfile.ZipFile(mutated, "a") as output:
            info = zipfile.ZipInfo("zz-unexpected", builder.ZIP_TIMESTAMP)
            info.compress_type = zipfile.ZIP_STORED
            info.create_system = 3
            info.external_attr = builder.FILE_MODE << 16
            output.writestr(info, b"unexpected")
        with self.assertRaisesRegex(builder.BuildError, "allow-list"):
            builder.validate_archive(mutated.getvalue(), entries)

    def test_archive_duplicate_and_traversal_paths_are_rejected(self):
        duplicate = self.zip_with([("a", b"1"), ("a", b"2")])
        traversal = self.zip_with([("../Info.json", b"{}")])
        redundant = self.zip_with([("lib//main.js", b"1")])
        with self.assertRaisesRegex(builder.BuildError, "duplicate"):
            builder.validate_archive(duplicate)
        with self.assertRaisesRegex(builder.BuildError, "not normalized"):
            builder.validate_archive(traversal)
        with self.assertRaisesRegex(builder.BuildError, "not normalized"):
            builder.validate_archive(redundant)

    def test_archive_nonfixed_metadata_compression_and_executable_mode_are_rejected(self):
        fixtures = {
            "timestamp": self.zip_with([("a", b"1")], timestamp=(2026, 1, 1, 0, 0, 0)),
            "compression": self.zip_with([("a", b"1" * 100)], compression=zipfile.ZIP_DEFLATED),
            "executable": self.zip_with([("a", b"1")], mode=stat.S_IFREG | 0o755),
            "symlink": self.zip_with([("a", b"target")], mode=stat.S_IFLNK | 0o777),
            "platform": self.zip_with([("a", b"1")], create_system=0),
        }
        for label, archive in fixtures.items():
            with self.subTest(label=label), self.assertRaises(builder.BuildError):
                builder.validate_archive(archive)

    def test_catalog_entries_bind_the_complete_installed_tree(self):
        bundle, archive, catalog = builder.build_artifacts(self.source)
        package_entries = builder.package_entries(self.source, bundle)
        value = json.loads(catalog)
        catalog_entries = value["entries"]
        catalog_paths = [entry["path"] for entry in catalog_entries]
        with zipfile.ZipFile(io.BytesIO(archive), "r") as packaged:
            archive_paths = packaged.namelist()

        self.assertTrue(catalog_entries)
        self.assertEqual(catalog_paths, sorted(package_entries))
        self.assertEqual(catalog_paths, archive_paths)
        self.assertEqual(catalog_paths, sorted(catalog_paths))
        self.assertEqual(len(catalog_paths), len(set(catalog_paths)))
        self.assertNotIn("anime4k.catalog.json", catalog_paths)

        entries_by_path = {entry["path"]: entry for entry in catalog_entries}
        for path, data in package_entries.items():
            with self.subTest(path=path):
                self.assertEqual(entries_by_path[path], {
                    "kind": "file",
                    "path": path,
                    "posixPermissions": 0o644,
                    "sha256": f"sha256:{builder.sha256(data)}",
                    "size": len(data),
                })

        self.assertIn("main.js", catalog_paths)
        self.assertTrue(any(path.startswith("lib/") for path in catalog_paths))
        self.assertTrue(any(path.startswith("ui/") for path in catalog_paths))
        self.assertTrue(any(path == "LICENSE" or path.startswith("licenses/") for path in catalog_paths))
        self.assertTrue(any(path.startswith("shaders/") for path in catalog_paths))

    def test_catalog_entry_tamper_missing_extra_duplicate_and_shape_drift_are_rejected(self):
        bundle, archive, catalog = builder.build_artifacts(self.source)
        del bundle
        manifest_bytes = (self.source / "manifest.json").read_bytes()
        value = json.loads(catalog)
        paths = [entry["path"] for entry in value["entries"]]

        tamper_paths = [
            "main.js",
            next(path for path in paths if path.startswith("lib/") and path.endswith(".js")),
            next(path for path in paths if path.startswith("ui/")),
            "LICENSE",
            next(path for path in paths if path.startswith("shaders/")),
        ]
        for path in tamper_paths:
            with self.subTest(tampered=path):
                mutated = json.loads(json.dumps(value))
                entry = next(item for item in mutated["entries"] if item["path"] == path)
                entry["sha256"] = "sha256:" + "0" * 64
                with self.assertRaisesRegex(builder.BuildError, "catalog"):
                    builder.validate_catalog(json.dumps(mutated).encode(), archive, manifest_bytes)

        extra = {
            "kind": "file",
            "path": "zz-extra.txt",
            "posixPermissions": 0o644,
            "sha256": "sha256:" + builder.sha256(b"extra"),
            "size": len(b"extra"),
        }
        mutations = {
            "missing entry": lambda entries: entries.pop(),
            "extra entry": lambda entries: entries.append(extra),
            "duplicate entry": lambda entries: entries.append(dict(entries[-1])),
            "wrong hash": lambda entries: entries[0].update(sha256="sha256:" + "0" * 64),
            "wrong size": lambda entries: entries[0].update(size=entries[0]["size"] + 1),
            "wrong mode": lambda entries: entries[0].update(posixPermissions=0o755),
            "wrong kind": lambda entries: entries[0].update(kind="directory"),
            "wrong path": lambda entries: entries[0].update(path="renamed.txt"),
            "empty entries": lambda entries: entries.clear(),
            "traversal path": lambda entries: entries[0].update(path="../escape"),
            "malformed path": lambda entries: entries[0].update(path="lib//broken.js"),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                mutated = json.loads(json.dumps(value))
                mutate(mutated["entries"])
                with self.assertRaisesRegex(builder.BuildError, "catalog"):
                    builder.validate_catalog(json.dumps(mutated).encode(), archive, manifest_bytes)

    def test_catalog_binds_archive_manifest_identifier_version_and_pin(self):
        bundle, archive, catalog = builder.build_artifacts(self.source)
        del bundle
        manifest_bytes = (self.source / "manifest.json").read_bytes()
        builder.validate_catalog(catalog, archive, manifest_bytes)
        value = json.loads(catalog)
        for key, replacement in (
            ("identifier", "invalid.example"),
            ("version", "9.9.9"),
            ("upstreamCommit", "0" * 40),
            ("contentManifestDigest", "sha256:" + "0" * 64),
        ):
            with self.subTest(key=key):
                mutated = dict(value)
                mutated[key] = replacement
                with self.assertRaisesRegex(builder.BuildError, "catalog"):
                    builder.validate_catalog(json.dumps(mutated).encode(), archive, manifest_bytes)

    def test_xcode_phase_is_check_only_with_declared_artifact_boundaries(self):
        inputs_path = REPOSITORY / "Configs" / "Anime4KPluginInputs.xcfilelist"
        outputs_path = REPOSITORY / "Configs" / "Anime4KPluginOutputs.xcfilelist"
        inputs = set(inputs_path.read_text().splitlines())
        expected_inputs = {
            "$(SRCROOT)/scripts/build-anime4k-plugin.py",
            "$(SRCROOT)/deps/plugins/anime4k.iinaplgz",
            "$(SRCROOT)/deps/plugins/anime4k.catalog.json",
            "$(SRCROOT)/deps/plugins/anime4k.trusted-catalogs.json",
            "$(SRCROOT)/deps/plugins-src/anime4k/trusted-catalogs/1.0.0.catalog.json",
            "$(SRCROOT)/deps/plugins-src/anime4k/trusted-catalogs/1.0.1.catalog.json",
            "$(SRCROOT)/deps/plugins-src/anime4k/trusted-catalogs/1.0.2.catalog.json",
        }
        expected_inputs.update(
            f"$(SRCROOT)/deps/plugins-src/anime4k/{relative}"
            for relative in builder.packaged_paths(self.source)
        )
        self.assertEqual(inputs, expected_inputs)
        self.assertEqual(outputs_path.read_text().splitlines(), [
            "$(BUILT_PRODUCTS_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/plugins/anime4k.iinaplgz",
            "$(BUILT_PRODUCTS_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/plugins/anime4k.catalog.json",
            "$(BUILT_PRODUCTS_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/plugins/anime4k.trusted-catalogs.json",
        ])
        project = (REPOSITORY / "iina.xcodeproj" / "project.pbxproj").read_text()
        phase_start = project.index("E3E720A12CD7073D003470BF /* Copy Default Plugins */ = {")
        phase_end = project.index("\n\t\t};", phase_start)
        phase = project[phase_start:phase_end]
        self.assertIn("Anime4KPluginInputs.xcfilelist", phase)
        self.assertIn("Anime4KPluginOutputs.xcfilelist", phase)
        self.assertIn("build-anime4k-plugin.py\\\" --check", phase)
        self.assertNotIn("build-anime4k-plugin.py\\\" --source-dir", phase)
        self.assertIn("cmp \\\"${ARCHIVE}", phase)
        self.assertIn("cmp \\\"${CATALOG}", phase)
        self.assertIn("cmp \\\"${TRUST_HISTORY}", phase)

    def test_host_local_path_and_unload_lifecycle_source_contract(self):
        file_api = (REPOSITORY / "iina" / "JavascriptAPIFile.swift").read_text()
        instance = (REPOSITORY / "iina" / "JavascriptPluginInstance.swift").read_text()
        player = (REPOSITORY / "iina" / "PlayerCore.swift").read_text()
        plugin = (REPOSITORY / "iina" / "JavascriptPlugin.swift").read_text()
        app_delegate = (REPOSITORY / "iina" / "AppDelegate.swift").read_text()

        self.assertIn("func resolveLocal(_ path: String) -> String?", file_api)
        self.assertIn("PluginLocalPathResolver(dataRoot: dataRoot, temporaryRoot: temporaryRoot)", file_api)
        resolve_local = file_api[file_api.index("func resolveLocal"):file_api.index("func exists")]
        self.assertNotIn("whenPermitted(to: .accessFileSystem)", resolve_local)

        prepare = instance[instance.index("func prepareForUnload()"):instance.index("func canAccess")]
        self.assertLess(prepare.index("guard !preparedForUnload"), prepare.index("typeof iinaPluginWillUnload === 'function'"))
        self.assertLess(prepare.index("typeof iinaPluginWillUnload === 'function'"), prepare.index("hook.call(withArguments: [])"))
        self.assertIn("ctx.exceptionHandler", instance)
        deinit = instance[instance.index("deinit {"):instance.index("func prepareForUnload()")]
        self.assertLess(deinit.index("prepareForUnload()"), deinit.index("removeAllTimers()"))
        self.assertLess(deinit.index("prepareForUnload()"), deinit.index("cleanUp(self)"))

        reload_player = player[player.index("func reloadPlugin("):player.index("// MARK: - Control")]
        self.assertLess(reload_player.index("oldInstance.prepareForUnload()"), reload_player.index("pluginMap.removeValue"))
        self.assertLess(reload_player.index("pluginMap.removeValue"), reload_player.index("JavascriptPluginInstance(player:"))
        clear_player = player[player.index("func clearPlugins()"):player.index("func loadPlugins()")]
        self.assertLess(clear_player.index("prepareForUnload()"), clear_player.index("pluginMap.removeAll()"))

        reload_global = plugin[plugin.index("func reloadGlobalInstance"):plugin.index("static func savePluginOrder")]
        first_unload = reload_global.index("unloadGlobalInstance()")
        self.assertLess(first_unload, reload_global.index("globalInstance = .init", first_unload))
        unload_global = reload_global[reload_global.index("private func unloadGlobalInstance"):]
        self.assertLess(unload_global.index("prepareForUnload()"), unload_global.index("globalInstance = nil"))

        reload_all_start = app_delegate.index("func reloadAllPlugins")
        reload_all = app_delegate[reload_all_start:app_delegate.index("func dumpDebugInfo", reload_all_start)]
        self.assertLess(reload_all.index("player.clearPlugins()"), reload_all.index("JavascriptPlugin.recreateAllPlugins()"))
        self.assertLess(reload_all.index("JavascriptPlugin.recreateAllPlugins()"), reload_all.index("JavascriptPlugin.loadGlobalInstances()"))


if __name__ == "__main__":
    unittest.main()

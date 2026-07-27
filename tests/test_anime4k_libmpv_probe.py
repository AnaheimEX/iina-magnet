#!/usr/bin/env python3

import importlib.util
import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
VALIDATOR_PATH = REPO_ROOT / "scripts" / "anime4k_libmpv_probe_validator.py"
RUNNER_PATH = REPO_ROOT / "scripts" / "run-anime4k-libmpv-probe.sh"
FIXTURE_PATH = REPO_ROOT / "tests" / "fixtures" / "anime4k-libmpv-probe.iinaplugin-dev"

SPEC = importlib.util.spec_from_file_location("anime4k_probe_validator", VALIDATOR_PATH)
assert SPEC is not None and SPEC.loader is not None
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class Anime4KLibmpvProbeTests(unittest.TestCase):
    def make_app(self, root, executable_body="#!/bin/sh\nexit 0\n"):
        app = root / "IINA.app"
        info = app / "Contents" / "Info.plist"
        executable = app / "Contents" / "MacOS" / "IINA"
        executable.parent.mkdir(parents=True)
        with info.open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "io.iina.probe-tests",
                    "CFBundleShortVersionString": "9.9.9",
                    "CFBundleVersion": "999",
                },
                handle,
            )
        executable.write_text(executable_body, encoding="utf-8")
        executable.chmod(0o755)
        return app

    def passing_result(self, expected):
        return {
            "schema_version": 1,
            "run_id": expected["run_id"],
            "timestamp": "2026-07-13T00:00:00.000Z",
            "app": {
                "path": expected["app"]["path"],
                "version": expected["app"]["version"],
                "build": expected["app"]["build"],
            },
            "libmpv_version": "0.40.0",
            "native_property": "glsl-shaders",
            "native_property_type": "array",
            "input_array": expected["input_array"],
            "readback_array": expected["input_array"],
            "owned_paths": expected["owned_paths"],
            "latest_state_input_array": expected["latest_state_input_array"],
            "latest_state_readback_array": expected["latest_state_input_array"],
            "cleanup_source_array": expected["latest_state_input_array"],
            "expected_cleanup_array": expected["expected_cleanup_array"],
            "latest_state_cleanup_readback": expected["expected_cleanup_array"],
            "elapsed_ms": 12,
            "checks": {name: True for name in VALIDATOR.REQUIRED_CHECKS},
            "verdict": "pass",
            "errors": [],
        }

    def test_prepare_builds_isolated_profile_and_hostile_path_corpus(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected = VALIDATOR.prepare_probe(root / "run", FIXTURE_PATH, self.make_app(root), 45)
            self.assertEqual(expected["app"]["bundle_id"], "io.iina.probe-tests")
            self.assertTrue(any(" " in value for value in expected["input_array"]))
            self.assertTrue(any("日本語" in value for value in expected["input_array"]))
            self.assertTrue(any(":" in Path(value).name for value in expected["input_array"]))
            duplicate = expected["feature_paths"]["duplicate"]
            self.assertGreaterEqual(expected["input_array"].count(duplicate), 2)
            self.assertTrue(str(expected["result_path"]).startswith(str(root / "run" / "home")))

    def test_strict_validator_accepts_exact_round_trip_and_latest_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected = VALIDATOR.prepare_probe(root / "run", FIXTURE_PATH, self.make_app(root), 45)
            self.assertEqual(VALIDATOR.validate_probe(self.passing_result(expected), expected), [])

    def test_strict_validator_rejects_string_fallback_and_reordering(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected = VALIDATOR.prepare_probe(root / "run", FIXTURE_PATH, self.make_app(root), 45)
            result = self.passing_result(expected)
            result["native_property_type"] = "string"
            result["readback_array"] = list(reversed(result["readback_array"]))
            problems = VALIDATOR.validate_probe(result, expected)
            self.assertTrue(any("did not return an array" in problem for problem in problems))
            self.assertTrue(any("readback_array" in problem for problem in problems))

    def test_strict_validator_rejects_stale_snapshot_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected = VALIDATOR.prepare_probe(root / "run", FIXTURE_PATH, self.make_app(root), 45)
            result = self.passing_result(expected)
            result["cleanup_source_array"] = expected["input_array"]
            result["latest_state_cleanup_readback"] = expected["input_array"]
            problems = VALIDATOR.validate_probe(result, expected)
            self.assertTrue(any("cleanup_source_array" in problem for problem in problems))
            self.assertTrue(any("latest_state_cleanup_readback" in problem for problem in problems))

    def test_cli_writes_contract_failure_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected = VALIDATOR.prepare_probe(root / "run", FIXTURE_PATH, self.make_app(root), 45)
            result = self.passing_result(expected)
            result.pop("native_property_type")
            input_path = root / "input.json"
            output_path = root / "output.json"
            input_path.write_text(json.dumps(result), encoding="utf-8")
            completed = subprocess.run(
                [
                    "python3", str(VALIDATOR_PATH), "validate",
                    "--input", str(input_path),
                    "--expected", str(root / "run" / "expected.json"),
                    "--output", str(output_path),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 2)
            evidence = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(evidence["verdict"], "contract-fail")
            self.assertEqual(evidence["validator"]["status"], "fail")

    def test_runner_rejects_timeout_above_hard_limit_offline(self):
        completed = subprocess.run(
            [
                str(RUNNER_PATH),
                "--app", "/missing/IINA.app",
                "--timeout", "46",
                "--output", "/tmp/unused-anime4k-probe.json",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 4)
        self.assertIn("1 to 45", completed.stderr)

    def test_runner_returns_timeout_and_writes_evidence_offline(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = self.make_app(root, "#!/bin/sh\nsleep 5\n")
            output = root / "timeout.json"
            completed = subprocess.run(
                [
                    str(RUNNER_PATH),
                    "--app", str(app),
                    "--timeout", "1",
                    "--output", str(output),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 3)
            self.assertEqual(json.loads(output.read_text(encoding="utf-8"))["verdict"], "timeout")

    def test_runner_returns_harness_failure_when_app_exits_offline(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = self.make_app(root, "#!/bin/sh\nexit 7\n")
            output = root / "harness-error.json"
            completed = subprocess.run(
                [
                    str(RUNNER_PATH),
                    "--app", str(app),
                    "--timeout", "2",
                    "--output", str(output),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 4)
            evidence = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(evidence["verdict"], "harness-error")
            self.assertIn("status 7", evidence["errors"][0])


if __name__ == "__main__":
    unittest.main()

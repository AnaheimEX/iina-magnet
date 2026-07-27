#!/usr/bin/env python3
"""Prepare and strictly validate the repository-owned Anime4K libmpv probe."""

import argparse
import json
import math
import plistlib
import re
import shutil
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path


SCHEMA_VERSION = 1
PLUGIN_ID = "io.iina.anime4k.libmpv-probe"
PLUGIN_ENABLED_KEY = "PluginEnabled." + PLUGIN_ID
REQUIRED_CHECKS = (
    "native_array",
    "exact_round_trip",
    "space_preserved",
    "unicode_preserved",
    "colon_preserved",
    "duplicate_preserved",
    "order_preserved",
    "latest_state_reread_exact",
    "owned_cleanup_exact",
    "non_owned_preserved",
)
REQUIRED_FIELDS = (
    "schema_version",
    "run_id",
    "timestamp",
    "app",
    "libmpv_version",
    "native_property",
    "native_property_type",
    "input_array",
    "readback_array",
    "owned_paths",
    "latest_state_input_array",
    "latest_state_readback_array",
    "cleanup_source_array",
    "expected_cleanup_array",
    "latest_state_cleanup_readback",
    "elapsed_ms",
    "checks",
    "verdict",
    "errors",
)


def utc_timestamp():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def read_json(path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(".{}.{}.tmp".format(path.name, uuid.uuid4().hex))
    with temporary.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    temporary.replace(path)


def read_app_info(app_path):
    info_path = app_path / "Contents" / "Info.plist"
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    required = ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")
    missing = [key for key in required if not isinstance(info.get(key), str) or not info[key]]
    if missing:
        raise ValueError("Info.plist is missing string values: {}".format(", ".join(missing)))
    return {
        "bundle_id": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
    }


def _shader_paths(root):
    shader_root = root / "shaders"
    return {
        "external_space": shader_root / "existing shader.glsl",
        "external_unicode": shader_root / "existing-日本語.glsl",
        "owned_space": shader_root / "owned shader.glsl",
        "owned_unicode": shader_root / "owned-日本語.glsl",
        "owned_colon": shader_root / "owned:colon.glsl",
        "latest_colon": shader_root / "latest:non-owned.glsl",
        "latest_space": shader_root / "latest non-owned.glsl",
    }


def prepare_probe(root, fixture, app_path, timeout_seconds):
    if timeout_seconds < 1 or timeout_seconds > 45:
        raise ValueError("timeout must be between 1 and 45 seconds")
    if not fixture.is_dir():
        raise ValueError("probe fixture does not exist: {}".format(fixture))
    required_fixture_files = ("Info.json", "main.js", "noop.glsl")
    missing = [name for name in required_fixture_files if not (fixture / name).is_file()]
    if missing:
        raise ValueError("probe fixture is missing: {}".format(", ".join(missing)))

    app_info = read_app_info(app_path)
    run_id = str(uuid.uuid4())
    home = root / "home"
    temp = root / "tmp"
    app_support = home / "Library" / "Application Support" / app_info["bundle_id"]
    plugins = app_support / "plugins"
    plugin_dest = plugins / "anime4k-libmpv-probe.iinaplugin-dev"
    preferences_dir = plugins / ".preferences"
    user_preferences_dir = home / "Library" / "Preferences"
    temp.mkdir(parents=True, exist_ok=True)
    preferences_dir.mkdir(parents=True, exist_ok=True)
    user_preferences_dir.mkdir(parents=True, exist_ok=True)
    shutil.copytree(str(fixture), str(plugin_dest))

    paths = _shader_paths(root)
    paths["external_space"].parent.mkdir(parents=True, exist_ok=True)
    for path in paths.values():
        shutil.copyfile(str(fixture / "noop.glsl"), str(path))

    owned_paths = [
        str(paths["owned_space"]),
        str(paths["owned_unicode"]),
        str(paths["owned_colon"]),
    ]
    input_array = [
        str(paths["external_space"]),
        str(paths["owned_space"]),
        str(paths["external_unicode"]),
        str(paths["owned_unicode"]),
        str(paths["owned_colon"]),
        str(paths["owned_space"]),
    ]
    latest_state_array = [
        str(paths["external_space"]),
        str(paths["owned_colon"]),
        str(paths["latest_colon"]),
        str(paths["owned_space"]),
        str(paths["owned_space"]),
        str(paths["external_unicode"]),
        str(paths["owned_unicode"]),
        str(paths["latest_space"]),
    ]
    expected_cleanup_array = [
        str(paths["external_space"]),
        str(paths["latest_colon"]),
        str(paths["external_unicode"]),
        str(paths["latest_space"]),
    ]
    feature_paths = {
        "space": str(paths["owned_space"]),
        "unicode": str(paths["owned_unicode"]),
        "colon": str(paths["owned_colon"]),
        "duplicate": str(paths["owned_space"]),
    }
    plugin_preferences = {
        "run_id": run_id,
        "app_path": str(app_path),
        "input_array": input_array,
        "owned_paths": owned_paths,
        "latest_state_array": latest_state_array,
        "expected_cleanup_array": expected_cleanup_array,
        "feature_paths": feature_paths,
    }
    with (preferences_dir / (PLUGIN_ID + ".plist")).open("wb") as handle:
        plistlib.dump(plugin_preferences, handle, fmt=plistlib.FMT_BINARY, sort_keys=True)

    user_defaults = {PLUGIN_ENABLED_KEY: True, "PluginOrder": [PLUGIN_ID]}
    with (user_preferences_dir / (app_info["bundle_id"] + ".plist")).open("wb") as handle:
        plistlib.dump(user_defaults, handle, fmt=plistlib.FMT_BINARY, sort_keys=True)

    (app_support / ".installedDefaultPlugins").touch()
    (app_support / (".firstLaunchAfter" + app_info["version"])).touch()

    result_path = plugins / ".data" / PLUGIN_ID / "probe-result.json"
    expected = {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id,
        "timeout_seconds": timeout_seconds,
        "app": {
            "path": str(app_path),
            "version": app_info["version"],
            "build": app_info["build"],
            "bundle_id": app_info["bundle_id"],
        },
        "input_array": input_array,
        "owned_paths": owned_paths,
        "latest_state_input_array": latest_state_array,
        "expected_cleanup_array": expected_cleanup_array,
        "feature_paths": feature_paths,
        "result_path": str(result_path),
    }
    write_json(root / "expected.json", expected)
    (root / "run-id.txt").write_text(run_id + "\n", encoding="utf-8")
    (root / "result-path.txt").write_text(str(result_path) + "\n", encoding="utf-8")
    return expected


def _is_string_array(value):
    return isinstance(value, list) and all(isinstance(item, str) for item in value)


def _parse_timestamp(value):
    if not isinstance(value, str) or not value:
        return False
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return True


def validate_probe(result, expected):
    problems = []
    if not isinstance(result, dict):
        return ["result must be a JSON object"]

    for field in REQUIRED_FIELDS:
        if field not in result:
            problems.append("missing required field: " + field)

    if result.get("schema_version") != SCHEMA_VERSION:
        problems.append("schema_version must be {}".format(SCHEMA_VERSION))
    run_id = result.get("run_id")
    if run_id != expected.get("run_id"):
        problems.append("run_id does not match the isolated harness run")
    if not isinstance(run_id, str) or not re.fullmatch(r"[0-9a-fA-F-]{36}", run_id):
        problems.append("run_id is not a UUID-shaped string")
    if not _parse_timestamp(result.get("timestamp")):
        problems.append("timestamp is not a valid ISO-8601 value")

    app = result.get("app")
    expected_app = expected.get("app", {})
    if not isinstance(app, dict):
        problems.append("app must be an object")
    else:
        for key in ("path", "version", "build"):
            if app.get(key) != expected_app.get(key):
                problems.append("app.{} does not match the launched Debug app".format(key))
    if not isinstance(result.get("libmpv_version"), str) or not result.get("libmpv_version"):
        problems.append("libmpv_version must be a non-empty string")
    if result.get("native_property") != "glsl-shaders":
        problems.append("native_property must be glsl-shaders")
    if result.get("native_property_type") != "array":
        problems.append("getNative(glsl-shaders) did not return an array")

    exact_arrays = {
        "input_array": expected.get("input_array"),
        "readback_array": expected.get("input_array"),
        "owned_paths": expected.get("owned_paths"),
        "latest_state_input_array": expected.get("latest_state_input_array"),
        "latest_state_readback_array": expected.get("latest_state_input_array"),
        "cleanup_source_array": expected.get("latest_state_input_array"),
        "expected_cleanup_array": expected.get("expected_cleanup_array"),
        "latest_state_cleanup_readback": expected.get("expected_cleanup_array"),
    }
    for key, expected_value in exact_arrays.items():
        actual = result.get(key)
        if not _is_string_array(actual):
            problems.append(key + " must be a string array")
        elif actual != expected_value:
            problems.append(key + " does not exactly match expected order and duplicates")

    feature_paths = expected.get("feature_paths", {})
    input_array = result.get("input_array")
    readback_array = result.get("readback_array")
    if _is_string_array(input_array) and _is_string_array(readback_array):
        for feature in ("space", "unicode", "colon"):
            value = feature_paths.get(feature)
            if not isinstance(value, str) or value not in input_array or value not in readback_array:
                problems.append(feature + " path was not preserved")
        duplicate = feature_paths.get("duplicate")
        if not isinstance(duplicate, str) or input_array.count(duplicate) < 2:
            problems.append("input does not contain the required duplicate path")
        elif readback_array.count(duplicate) != input_array.count(duplicate):
            problems.append("duplicate path count changed during native round-trip")

    elapsed = result.get("elapsed_ms")
    max_elapsed = expected.get("timeout_seconds", 45) * 1000
    if (not isinstance(elapsed, (int, float)) or isinstance(elapsed, bool) or
            not math.isfinite(elapsed) or elapsed < 0 or elapsed > max_elapsed):
        problems.append("elapsed_ms is outside the configured timeout")

    checks = result.get("checks")
    if not isinstance(checks, dict):
        problems.append("checks must be an object")
    else:
        for check in REQUIRED_CHECKS:
            if checks.get(check) is not True:
                problems.append("check is not true: " + check)
    if result.get("verdict") != "pass":
        problems.append("plugin verdict is not pass")
    if result.get("errors") != []:
        problems.append("plugin errors must be an empty array")
    return problems


def failure_document(expected, verdict, message, elapsed_ms=0):
    expected_app = expected.get("app", {})
    return {
        "schema_version": SCHEMA_VERSION,
        "run_id": expected.get("run_id", ""),
        "timestamp": utc_timestamp(),
        "app": {
            "path": expected_app.get("path", ""),
            "version": expected_app.get("version", ""),
            "build": expected_app.get("build", ""),
        },
        "libmpv_version": None,
        "native_property": "glsl-shaders",
        "native_property_type": "unavailable",
        "input_array": expected.get("input_array", []),
        "readback_array": None,
        "owned_paths": expected.get("owned_paths", []),
        "latest_state_input_array": expected.get("latest_state_input_array", []),
        "latest_state_readback_array": None,
        "cleanup_source_array": None,
        "expected_cleanup_array": expected.get("expected_cleanup_array", []),
        "latest_state_cleanup_readback": None,
        "elapsed_ms": elapsed_ms,
        "checks": {check: False for check in REQUIRED_CHECKS},
        "verdict": verdict,
        "errors": [message],
        "validator": {
            "status": "not-run",
            "validated_at": utc_timestamp(),
            "errors": [message],
        },
    }


def validated_document(result, expected, problems):
    document = dict(result) if isinstance(result, dict) else failure_document(
        expected, "contract-fail", "result is not a JSON object")
    document["plugin_verdict"] = document.get("verdict")
    document["verdict"] = "pass" if not problems else "contract-fail"
    document["validator"] = {
        "status": "pass" if not problems else "fail",
        "validated_at": utc_timestamp(),
        "errors": problems,
    }
    return document


def command_prepare(args):
    prepare_probe(args.root.resolve(), args.fixture.resolve(), args.app.resolve(), args.timeout)
    return 0


def command_validate(args):
    expected = read_json(args.expected)
    try:
        result = read_json(args.input)
    except (OSError, json.JSONDecodeError) as error:
        result = failure_document(expected, "contract-fail", "cannot read plugin result: {}".format(error))
    problems = validate_probe(result, expected)
    write_json(args.output, validated_document(result, expected, problems))
    for problem in problems:
        print("contract failure: " + problem, file=sys.stderr)
    return 2 if problems else 0


def command_failure(args):
    expected = read_json(args.expected)
    write_json(args.output, failure_document(expected, args.verdict, args.message, args.elapsed_ms))
    return 0


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare = subparsers.add_parser("prepare", help="create an isolated probe profile")
    prepare.add_argument("--root", type=Path, required=True)
    prepare.add_argument("--fixture", type=Path, required=True)
    prepare.add_argument("--app", type=Path, required=True)
    prepare.add_argument("--timeout", type=int, required=True)
    prepare.set_defaults(handler=command_prepare)
    validate = subparsers.add_parser("validate", help="strictly validate plugin JSON")
    validate.add_argument("--input", type=Path, required=True)
    validate.add_argument("--expected", type=Path, required=True)
    validate.add_argument("--output", type=Path, required=True)
    validate.set_defaults(handler=command_validate)
    failure = subparsers.add_parser("failure", help="write timeout or harness-failure evidence")
    failure.add_argument("--expected", type=Path, required=True)
    failure.add_argument("--output", type=Path, required=True)
    failure.add_argument("--verdict", choices=("timeout", "harness-error"), required=True)
    failure.add_argument("--message", required=True)
    failure.add_argument("--elapsed-ms", type=int, default=0)
    failure.set_defaults(handler=command_failure)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return args.handler(args)
    except (OSError, ValueError, plistlib.InvalidFileException, json.JSONDecodeError) as error:
        print("probe harness error: {}".format(error), file=sys.stderr)
        return 4


if __name__ == "__main__":
    raise SystemExit(main())

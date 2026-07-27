#!/usr/bin/env python3
"""Build and verify the bundled Anime4K IINA plugin reproducibly."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tempfile
import zipfile


EXPECTED_IDENTIFIER = "io.iina.magnet.anime4k"
EXPECTED_VERSION = "1.0.2"
EXPECTED_UPSTREAM_COMMIT = "7684e9586f8dcc738af08a1cdceb024cc184f426"
EXPECTED_PACKAGE_SCHEMA = 1
EXPECTED_SHADER_BUNDLE_VERSION = 1
TRUST_HISTORY_SCHEMA_VERSION = 1
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
FILE_MODE = stat.S_IFREG | 0o644
UNLICENSE_SHADER_IDS = {
    "Anime4K_AutoDownscalePre_x2",
    "Anime4K_AutoDownscalePre_x4",
}
UNLICENSE_URL = "https://unlicense.org"
UNLICENSE_COMMENT = f"// For more information, please refer to <{UNLICENSE_URL}>"

EXPECTED_LICENSE_HASHES = {
    "LICENSE": "589ed823e9a84c56feb95ac58e7cf384626b9cbf4fda2a907bc36e103de1bad2",
    "licenses/AutoDownscale-Unlicense-NOTICE.txt": "6d27ef642b8b4a30626824b85d846f8b7df86c10ec9fd8d52799d844e47d7d5a",
    "licenses/Anime4K-LICENSE.txt": "5bad448b737378e3d0c977ad0d0521fa37ad279a7e76ea9a31d9257eeb6953f5",
}

# This is the exact reviewed subset from the pinned Anime4K commit. Keeping the
# records here, rather than trusting manifest.json alone, prevents coordinated
# manifest/source drift from silently changing the shipped shader payload.
EXPECTED_SHADERS = [
    ("Anime4K_Clamp_Highlights", "Anime4K_Clamp_Highlights.glsl", 0, "a2a9bf7fbc1d75d09660ca2e701e4d7fb0cf5457b94da47e1825032fa2b3671a", 2795, "glsl/Restore/Anime4K_Clamp_Highlights.glsl"),
    ("Anime4K_Restore_CNN_M", "Anime4K_Restore_CNN_M.glsl", 1, "67ea3ed26539e8de3b7d307688535d2ff17e8d147e11dda0247da7770dbecf41", 35916, "glsl/Restore/Anime4K_Restore_CNN_M.glsl"),
    ("Anime4K_Restore_CNN_S", "Anime4K_Restore_CNN_S.glsl", 2, "97c24dc370ab300c108bfaa09db7f175aeff343674842c299cf3940a3d330427", 17136, "glsl/Restore/Anime4K_Restore_CNN_S.glsl"),
    ("Anime4K_Restore_CNN_VL", "Anime4K_Restore_CNN_VL.glsl", 3, "35036722733305cd4d4e57660b883bbe2569ba2914033c254327107d7b77e35e", 144075, "glsl/Restore/Anime4K_Restore_CNN_VL.glsl"),
    ("Anime4K_Restore_CNN_Soft_M", "Anime4K_Restore_CNN_Soft_M.glsl", 4, "a78a2c76898e08e09e442a9628c64208c26e8e15789649b8755223f009794c02", 36016, "glsl/Restore/Anime4K_Restore_CNN_Soft_M.glsl"),
    ("Anime4K_Restore_CNN_Soft_S", "Anime4K_Restore_CNN_Soft_S.glsl", 5, "9f6867f2ef42786729522d86fe24147cb4ea145418e3974df70496acf52dc392", 17198, "glsl/Restore/Anime4K_Restore_CNN_Soft_S.glsl"),
    ("Anime4K_Restore_CNN_Soft_VL", "Anime4K_Restore_CNN_Soft_VL.glsl", 6, "094334b0e20c1a201fe4941c7c68de72451e5aee9efb5524d7fb82b12dca64b9", 144204, "glsl/Restore/Anime4K_Restore_CNN_Soft_VL.glsl"),
    ("Anime4K_Upscale_CNN_x2_M", "Anime4K_Upscale_CNN_x2_M.glsl", 7, "716e02098a68f0d648761f2b96b4dd139e1cb09b174bb369fca3aa34328fff7e", 37685, "glsl/Upscale/Anime4K_Upscale_CNN_x2_M.glsl"),
    ("Anime4K_Upscale_CNN_x2_S", "Anime4K_Upscale_CNN_x2_S.glsl", 8, "4c53ec2e287908f7ee7bcb266b0170421626d663576468b7d7dafc62962649a4", 18638, "glsl/Upscale/Anime4K_Upscale_CNN_x2_S.glsl"),
    ("Anime4K_Upscale_CNN_x2_VL", "Anime4K_Upscale_CNN_x2_VL.glsl", 9, "5638fe31c37c151a3443fea3451a3ef91af073f4dbb9615f6c0d1e29db11493d", 146743, "glsl/Upscale/Anime4K_Upscale_CNN_x2_VL.glsl"),
    ("Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x2.glsl", 10, "8c58291740146bd766a4d73f132775a797fe80f7d07919b5d767e27a5dc85656", 1560, "glsl/Upscale/Anime4K_AutoDownscalePre_x2.glsl"),
    ("Anime4K_AutoDownscalePre_x4", "Anime4K_AutoDownscalePre_x4.glsl", 11, "5af62d8cd844916dc1126613e13bad3beab195787f93a71200b47c6ec78f2e41", 1568, "glsl/Upscale/Anime4K_AutoDownscalePre_x4.glsl"),
    ("Anime4K_Upscale_Denoise_CNN_x2_M", "Anime4K_Upscale_Denoise_CNN_x2_M.glsl", 12, "8c72b042e2301fe66a45c3089720459148e2504cd72af16f9c0d5017ff14181e", 37714, "glsl/Upscale+Denoise/Anime4K_Upscale_Denoise_CNN_x2_M.glsl"),
    ("Anime4K_Upscale_Denoise_CNN_x2_VL", "Anime4K_Upscale_Denoise_CNN_x2_VL.glsl", 13, "359c48fe5a317fbc6b706ce368401eef496e84ed98abac7a43efebca2b65d79b", 146811, "glsl/Upscale+Denoise/Anime4K_Upscale_Denoise_CNN_x2_VL.glsl"),
]

EXPECTED_PRESETS = {
    "fast": {
        "A": ["Anime4K_Clamp_Highlights", "Anime4K_Restore_CNN_M", "Anime4K_Upscale_CNN_x2_M", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Upscale_CNN_x2_S"],
        "A+A": ["Anime4K_Clamp_Highlights", "Anime4K_Restore_CNN_M", "Anime4K_Upscale_CNN_x2_M", "Anime4K_Restore_CNN_S", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Upscale_CNN_x2_S"],
        "B": ["Anime4K_Clamp_Highlights", "Anime4K_Restore_CNN_Soft_M", "Anime4K_Upscale_CNN_x2_M", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Upscale_CNN_x2_S"],
        "B+B": ["Anime4K_Clamp_Highlights", "Anime4K_Restore_CNN_Soft_M", "Anime4K_Upscale_CNN_x2_M", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Restore_CNN_Soft_S", "Anime4K_Upscale_CNN_x2_S"],
        "C": ["Anime4K_Clamp_Highlights", "Anime4K_Upscale_Denoise_CNN_x2_M", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Upscale_CNN_x2_S"],
        "C+A": ["Anime4K_Clamp_Highlights", "Anime4K_Upscale_Denoise_CNN_x2_M", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Restore_CNN_S", "Anime4K_Upscale_CNN_x2_S"],
    },
    "hq": {
        "A": ["Anime4K_Clamp_Highlights", "Anime4K_Restore_CNN_VL", "Anime4K_Upscale_CNN_x2_VL", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Upscale_CNN_x2_M"],
        "A+A": ["Anime4K_Clamp_Highlights", "Anime4K_Restore_CNN_VL", "Anime4K_Upscale_CNN_x2_VL", "Anime4K_Restore_CNN_M", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Upscale_CNN_x2_M"],
        "B": ["Anime4K_Clamp_Highlights", "Anime4K_Restore_CNN_Soft_VL", "Anime4K_Upscale_CNN_x2_VL", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Upscale_CNN_x2_M"],
        "B+B": ["Anime4K_Clamp_Highlights", "Anime4K_Restore_CNN_Soft_VL", "Anime4K_Upscale_CNN_x2_VL", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Restore_CNN_Soft_M", "Anime4K_Upscale_CNN_x2_M"],
        "C": ["Anime4K_Clamp_Highlights", "Anime4K_Upscale_Denoise_CNN_x2_VL", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Upscale_CNN_x2_M"],
        "C+A": ["Anime4K_Clamp_Highlights", "Anime4K_Upscale_Denoise_CNN_x2_VL", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Restore_CNN_M", "Anime4K_Upscale_CNN_x2_M"],
    },
    "off": [],
}

BUNDLE_PREFIX = b'"use strict";\n\n// Generated by scripts/build-anime4k-plugin.py. Do not edit.\nmodule.exports = '
BUNDLE_SUFFIX = b";\n"


class BuildError(RuntimeError):
    """Raised when source or committed artifacts violate the package contract."""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise BuildError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json_bytes(data: bytes, label: str):
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=_reject_duplicate_keys)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise BuildError(f"invalid UTF-8 JSON in {label}: {error}") from error


def read_required(path: Path) -> bytes:
    try:
        data = path.read_bytes()
    except OSError as error:
        raise BuildError(f"cannot read required file {path}: {error}") from error
    if not data:
        raise BuildError(f"required file is empty: {path}")
    return data


def expected_shader_records() -> list[dict]:
    return [
        {
            "file": filename,
            "id": shader_id,
            "license": "Unlicense" if shader_id in UNLICENSE_SHADER_IDS else "MIT",
            "order": order,
            "sha256": digest,
            "size": size,
            "sourcePath": source_path,
        }
        for shader_id, filename, order, digest, size, source_path in EXPECTED_SHADERS
    ]


def validate_manifest(manifest: object) -> dict:
    if not isinstance(manifest, dict):
        raise BuildError("manifest.json must contain an object")
    expected_keys = {"plugin", "presets", "schemaVersion", "shaderBundleVersion", "shaders", "upstream"}
    if set(manifest) != expected_keys:
        raise BuildError("manifest.json top-level keys drifted")
    if manifest["plugin"] != {"identifier": EXPECTED_IDENTIFIER, "version": EXPECTED_VERSION}:
        raise BuildError("manifest plugin identifier/version drifted")
    if manifest["schemaVersion"] != EXPECTED_PACKAGE_SCHEMA:
        raise BuildError("manifest schemaVersion drifted")
    if manifest["shaderBundleVersion"] != EXPECTED_SHADER_BUNDLE_VERSION:
        raise BuildError("manifest shaderBundleVersion drifted")
    if manifest["upstream"] != {
        "commit": EXPECTED_UPSTREAM_COMMIT,
        "licenses": ["MIT", "Unlicense"],
        "repository": "bloc97/Anime4K",
    }:
        raise BuildError("manifest upstream pin/provenance drifted")
    if manifest["presets"] != EXPECTED_PRESETS:
        raise BuildError("manifest preset chains drifted from approved upstream templates")
    if manifest["shaders"] != expected_shader_records():
        raise BuildError("manifest shader allow-list/hash/size/order drifted")
    return manifest


def validate_info(info: object, manifest_digest: str) -> dict:
    if not isinstance(info, dict):
        raise BuildError("Info.json must contain an object")
    if info.get("identifier") != EXPECTED_IDENTIFIER or info.get("version") != EXPECTED_VERSION:
        raise BuildError("Info.json identifier/version drifted")
    if info.get("entry") != "main.js":
        raise BuildError("Info.json entry must remain main.js")
    author = info.get("author")
    if not isinstance(author, dict) or not isinstance(author.get("name"), str) or not author["name"]:
        raise BuildError("Info.json author.name is required")
    if info.get("permissions") != ["show-osd"]:
        raise BuildError("Info.json permissions must be exactly ['show-osd']")
    expected_defaults = {
        "autoApply": True,
        "hasActivated": False,
        "lastMode": "A",
        "lastQuality": "fast",
        "mode": "off",
        "quality": "fast",
        "schemaVersion": EXPECTED_PACKAGE_SCHEMA,
        "shaderBundleVersion": EXPECTED_SHADER_BUNDLE_VERSION,
        "shortcutHintAcknowledged": False,
        "shortcuts": {
            "A": "Ctrl+1", "A+A": "Ctrl+4", "B": "Ctrl+2", "B+B": "Ctrl+5",
            "C": "Ctrl+3", "C+A": "Ctrl+6", "fast": "Ctrl+7", "hq": "Ctrl+8", "off": "Ctrl+0",
        },
    }
    if info.get("preferenceDefaults") != expected_defaults:
        raise BuildError("Info.json safe defaults or shortcut contract drifted")
    expected_marker = {
        "contentManifestDigest": f"sha256:{manifest_digest}",
        "owner": "iina-magnet",
        "packageSchemaVersion": EXPECTED_PACKAGE_SCHEMA,
        "version": EXPECTED_VERSION,
    }
    if info.get("iinaMagnetManaged") != expected_marker:
        raise BuildError("Info.json managed marker/content digest drifted")
    return info


def validate_source(source_dir: Path) -> tuple[dict, dict, dict[str, str], bytes]:
    manifest_bytes = read_required(source_dir / "manifest.json")
    manifest = validate_manifest(load_json_bytes(manifest_bytes, "manifest.json"))
    info = validate_info(
        load_json_bytes(read_required(source_dir / "Info.json"), "Info.json"),
        sha256(manifest_bytes),
    )

    expected_names = {record[1] for record in EXPECTED_SHADERS}
    shader_dir = source_dir / "shaders"
    actual_names = {path.name for path in shader_dir.iterdir() if path.is_file()} if shader_dir.is_dir() else set()
    if actual_names != expected_names:
        missing = sorted(expected_names - actual_names)
        extra = sorted(actual_names - expected_names)
        raise BuildError(f"shader allow-list mismatch; missing={missing}, unexpected={extra}")

    shader_texts: dict[str, str] = {}
    for shader_id, filename, _order, expected_hash, expected_size, _source_path in EXPECTED_SHADERS:
        data = read_required(shader_dir / filename)
        if len(data) != expected_size or sha256(data) != expected_hash:
            raise BuildError(f"shader integrity mismatch: {filename}")
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as error:
            raise BuildError(f"shader is not valid UTF-8: {filename}") from error
        if text.encode("utf-8") != data:
            raise BuildError(f"shader UTF-8 round-trip mismatch: {filename}")
        shader_texts[shader_id] = text

    for relative, expected_hash in EXPECTED_LICENSE_HASHES.items():
        data = read_required(source_dir / relative)
        if sha256(data) != expected_hash:
            raise BuildError(f"retained license drifted: {relative}")

    notices = read_required(source_dir / "THIRD_PARTY_NOTICES.md").decode("utf-8")
    notice_requirements = (
        EXPECTED_UPSTREAM_COMMIT,
        "Twelve files",
        "MIT",
        "Copyright (c) 2019 bloc97",
        "Anime4K_AutoDownscalePre_x2.glsl",
        "Anime4K_AutoDownscalePre_x4.glsl",
        "Unlicense",
        "24-line public-domain dedication",
        "no standalone Unlicense file",
    )
    if any(required not in notices for required in notice_requirements):
        raise BuildError("THIRD_PARTY_NOTICES.md is missing exact mixed-license provenance")
    fork_notice = read_required(source_dir / "FORK_NOTICE.md").decode("utf-8")
    if any(required not in fork_notice for required in (
        "GNU GPL version 3", "independent", "Twelve shader", "Unlicense",
        "yorkyang2333/iina-anime4k", "a416d4c669f4136006e5a9bbe3d27dcf64471bbd",
    )):
        raise BuildError("FORK_NOTICE.md is missing fork implementation provenance")
    return manifest, info, shader_texts, manifest_bytes


NETWORK_URL_PATTERN = re.compile(r"(?i)(?:https?|wss?|ftp)://[^\s\\\"'<>]+")
NETWORK_CAPABILITY_PATTERNS = (
    re.compile(r"(?i)\bfetch\s*\("),
    re.compile(r"(?i)\bXMLHttpRequest\b"),
    re.compile(r"(?i)\bWebSocket\b"),
    re.compile(r"(?i)\bEventSource\b"),
    re.compile(r"(?i)\bsendBeacon\b"),
    re.compile(r"(?i)\bnetwork-request\b"),
    re.compile(r"(?i)\bnode:(?:http|https|net|tls|dgram)\b"),
    re.compile(r"(?i)\brequire\s*\(\s*[\"'](?:http|https|net|tls|dgram)[\"']"),
    re.compile(r"(?i)\biina\s*(?:\.\s*(?:http|ws)\b|\[\s*[\"'](?:http|ws)[\"']\s*\])"),
    re.compile(r"(?i)(?:src|href|action)\s*=\s*[\"']//"),
    re.compile(r"(?i)url\s*\(\s*[\"']?//"),
    re.compile(r"(?i)\b(?:curl|wget)\s+"),
)


def is_packaged_runtime_path(name: str) -> bool:
    path = PurePosixPath(name)
    return (
        name in {"Info.json", "manifest.json", "main.js"}
        or path.suffix in {".js", ".html", ".css", ".glsl"}
    )


def validate_packaged_runtime_network_surface(entries: dict[str, bytes]) -> None:
    """Reject network surfaces, except the two immutable upstream license URLs."""
    raw_unlicense_paths = {
        f"shaders/{shader_id}.glsl"
        for shader_id in UNLICENSE_SHADER_IDS
    }
    scanned = {name for name in entries if is_packaged_runtime_path(name)}
    expected_runtime = {
        "Info.json", "manifest.json", "main.js", "lib/integrity.js", "lib/presets.js",
        "lib/reconcile.js", "lib/runtime.js", "lib/sha256.js", "lib/shader-bundle.js", "lib/shortcuts.js",
        "lib/state.js", "lib/telemetry.js",
        "ui/sidebar.css", "ui/sidebar.html", "ui/sidebar.js",
    }
    expected_runtime.update(f"shaders/{filename}" for _shader_id, filename, *_rest in EXPECTED_SHADERS)
    if scanned != expected_runtime:
        raise BuildError("packaged runtime network scan coverage drifted")

    for name in sorted(scanned):
        try:
            text = entries[name].decode("utf-8")
        except UnicodeDecodeError as error:
            raise BuildError(f"packaged runtime is not UTF-8: {name}") from error
        for pattern in NETWORK_CAPABILITY_PATTERNS:
            match = pattern.search(text)
            if match:
                raise BuildError(f"runtime network capability token {match.group(0)!r} in {name}")

        urls = NETWORK_URL_PATTERN.findall(text)
        if name in raw_unlicense_paths:
            if urls != [UNLICENSE_URL] or text.count(UNLICENSE_COMMENT) != 1:
                raise BuildError(f"Unlicense URL allowance drifted in {name}")
        elif name == "lib/shader-bundle.js":
            if urls != [UNLICENSE_URL, UNLICENSE_URL]:
                raise BuildError("generated bundle Unlicense URL allowance drifted")
            payload = decode_bundle(entries[name])
            for shader_id, shader_text in payload["shaders"].items():
                expected_count = 1 if shader_id in UNLICENSE_SHADER_IDS else 0
                if shader_text.count(UNLICENSE_COMMENT) != expected_count:
                    raise BuildError(f"generated bundle Unlicense provenance drifted for {shader_id}")
        elif urls:
            raise BuildError(f"runtime network URL token {urls[0]!r} in {name}")


def render_bundle(manifest: dict, shader_texts: dict[str, str]) -> bytes:
    payload = {"manifest": manifest, "shaders": shader_texts}
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2, separators=(",", ": ")).encode("utf-8")
    return BUNDLE_PREFIX + encoded + BUNDLE_SUFFIX


def decode_bundle(data: bytes) -> dict:
    if not data.startswith(BUNDLE_PREFIX) or not data.endswith(BUNDLE_SUFFIX):
        raise BuildError("generated shader bundle wrapper drifted")
    payload = load_json_bytes(data[len(BUNDLE_PREFIX):-len(BUNDLE_SUFFIX)], "lib/shader-bundle.js")
    if not isinstance(payload, dict) or set(payload) != {"manifest", "shaders"}:
        raise BuildError("generated shader bundle payload shape drifted")
    return payload


def packaged_paths(source_dir: Path) -> list[str]:
    fixed = [
        "FORK_NOTICE.md", "Info.json", "LICENSE", "THIRD_PARTY_NOTICES.md",
        "lib/integrity.js", "lib/presets.js", "lib/reconcile.js", "lib/runtime.js",
        "lib/sha256.js", "lib/shader-bundle.js", "lib/shortcuts.js", "lib/state.js", "lib/telemetry.js",
        "licenses/Anime4K-LICENSE.txt",
        "licenses/AutoDownscale-Unlicense-NOTICE.txt",
        "main.js", "manifest.json", "ui/sidebar.css", "ui/sidebar.html", "ui/sidebar.js",
    ]
    fixed.extend(f"shaders/{filename}" for _shader_id, filename, *_rest in EXPECTED_SHADERS)
    paths = sorted(fixed)
    for relative in paths:
        if relative != "lib/shader-bundle.js":
            read_required(source_dir / relative)
    return paths


def package_entries(source_dir: Path, bundle_bytes: bytes) -> dict[str, bytes]:
    entries = {}
    for relative in packaged_paths(source_dir):
        entries[relative] = bundle_bytes if relative == "lib/shader-bundle.js" else read_required(source_dir / relative)
    return entries


def build_archive(entries: dict[str, bytes]) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED, strict_timestamps=True) as archive:
        for name in sorted(entries):
            info = zipfile.ZipInfo(name, ZIP_TIMESTAMP)
            info.compress_type = zipfile.ZIP_STORED
            info.create_system = 3
            info.external_attr = FILE_MODE << 16
            archive.writestr(info, entries[name])
    return output.getvalue()


def validate_archive(archive_bytes: bytes, expected_entries: dict[str, bytes] | None = None) -> None:
    try:
        archive = zipfile.ZipFile(io.BytesIO(archive_bytes), "r")
    except (OSError, zipfile.BadZipFile) as error:
        raise BuildError(f"invalid plugin archive: {error}") from error
    with archive:
        infos = archive.infolist()
        names = [info.filename for info in infos]
        if len(names) != len(set(names)):
            raise BuildError("archive contains duplicate paths")
        if names != sorted(names):
            raise BuildError("archive paths are not in fixed sorted order")
        for info in infos:
            path = PurePosixPath(info.filename)
            if (
                path.is_absolute()
                or path.as_posix() != info.filename
                or "\\" in info.filename
                or any(part in ("", ".", "..") for part in path.parts)
            ):
                raise BuildError(f"archive path is not normalized: {info.filename}")
            if info.is_dir():
                raise BuildError(f"archive must not contain directory entries: {info.filename}")
            if info.compress_type != zipfile.ZIP_STORED:
                raise BuildError(f"archive entry is not ZIP_STORED: {info.filename}")
            if info.date_time != ZIP_TIMESTAMP:
                raise BuildError(f"archive entry timestamp is not fixed: {info.filename}")
            if info.create_system != 3:
                raise BuildError(f"archive entry platform metadata drifted: {info.filename}")
            mode = info.external_attr >> 16
            if mode != FILE_MODE or mode & 0o111:
                raise BuildError(f"archive entry mode is not fixed non-executable 0644: {info.filename}")
        if expected_entries is not None:
            if names != sorted(expected_entries):
                raise BuildError("archive entry allow-list drifted")
            for name, expected in expected_entries.items():
                if archive.read(name) != expected:
                    raise BuildError(f"archive content drifted: {name}")


def catalog_entries_from_archive(archive_bytes: bytes) -> list[dict]:
    """Return the trusted, sorted full installed-tree inventory."""
    validate_archive(archive_bytes)
    with zipfile.ZipFile(io.BytesIO(archive_bytes), "r") as archive:
        result = []
        for info in archive.infolist():
            mode = info.external_attr >> 16
            if not stat.S_ISREG(mode):
                raise BuildError(f"catalog refuses non-regular archive entry: {info.filename}")
            data = archive.read(info.filename)
            result.append({
                "kind": "file",
                "path": info.filename,
                "posixPermissions": stat.S_IMODE(mode),
                "sha256": f"sha256:{sha256(data)}",
                "size": len(data),
            })
    if not result:
        raise BuildError("production catalog entries must not be empty")
    if [entry["path"] for entry in result] != sorted(entry["path"] for entry in result):
        raise BuildError("catalog entries are not sorted")
    return result


def render_catalog(archive_bytes: bytes, manifest_bytes: bytes) -> bytes:
    catalog = {
        "archive": {
            "file": "anime4k.iinaplgz",
            "sha256": f"sha256:{sha256(archive_bytes)}",
            "size": len(archive_bytes),
        },
        "contentManifestDigest": f"sha256:{sha256(manifest_bytes)}",
        "entries": catalog_entries_from_archive(archive_bytes),
        "identifier": EXPECTED_IDENTIFIER,
        "packageSchemaVersion": EXPECTED_PACKAGE_SCHEMA,
        "upstreamCommit": EXPECTED_UPSTREAM_COMMIT,
        "version": EXPECTED_VERSION,
    }
    return (json.dumps(catalog, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def validate_catalog(catalog_bytes: bytes, archive_bytes: bytes, manifest_bytes: bytes) -> None:
    catalog = load_json_bytes(catalog_bytes, "anime4k.catalog.json")
    expected = load_json_bytes(render_catalog(archive_bytes, manifest_bytes), "expected catalog")
    if catalog != expected:
        raise BuildError("external trusted catalog is stale or drifted")


def _is_canonical_digest(value: object) -> bool:
    return isinstance(value, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", value) is not None


def validate_historical_catalog(catalog: object, label: str = "historical catalog") -> dict:
    """Validate full-tree rollback metadata without requiring the old archive."""
    if not isinstance(catalog, dict):
        raise BuildError(f"{label} must contain an object")
    expected_keys = {
        "archive", "contentManifestDigest", "entries", "identifier",
        "packageSchemaVersion", "upstreamCommit", "version",
    }
    if set(catalog) != expected_keys:
        raise BuildError(f"{label} keys drifted")
    if catalog["identifier"] != EXPECTED_IDENTIFIER:
        raise BuildError(f"{label} identifier drifted")
    if catalog["packageSchemaVersion"] != EXPECTED_PACKAGE_SCHEMA:
        raise BuildError(f"{label} package schema drifted")
    if not isinstance(catalog["upstreamCommit"], str) or not re.fullmatch(
        r"[0-9a-f]{40}", catalog["upstreamCommit"]
    ):
        raise BuildError(f"{label} upstream commit is not canonical")
    version = catalog["version"]
    if not isinstance(version, str) or not re.fullmatch(
        r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
        r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
        r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?",
        version,
    ):
        raise BuildError(f"{label} version is not canonical SemVer")
    prerelease = version.split("+", 1)[0].split("-", 1)
    if len(prerelease) == 2 and any(
        identifier.isdigit() and len(identifier) > 1 and identifier.startswith("0")
        for identifier in prerelease[1].split(".")
    ):
        raise BuildError(f"{label} version is not canonical SemVer")
    if not _is_canonical_digest(catalog["contentManifestDigest"]):
        raise BuildError(f"{label} content manifest digest is not canonical")

    archive = catalog["archive"]
    if not isinstance(archive, dict) or set(archive) != {"file", "sha256", "size"}:
        raise BuildError(f"{label} archive metadata drifted")
    if archive["file"] != "anime4k.iinaplgz" or not _is_canonical_digest(archive["sha256"]):
        raise BuildError(f"{label} archive identity or digest drifted")
    if isinstance(archive["size"], bool) or not isinstance(archive["size"], int) or archive["size"] <= 0:
        raise BuildError(f"{label} archive size is invalid")

    entries = catalog["entries"]
    if not isinstance(entries, list) or not entries:
        raise BuildError(f"{label} full-tree entries are missing")
    paths = []
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {
            "kind", "path", "posixPermissions", "sha256", "size",
        }:
            raise BuildError(f"{label} entry shape drifted")
        path_value = entry["path"]
        if not isinstance(path_value, str):
            raise BuildError(f"{label} entry path is invalid")
        path = PurePosixPath(path_value)
        if (
            path.is_absolute()
            or path.as_posix() != path_value
            or "\\" in path_value
            or any(part in ("", ".", "..") for part in path.parts)
        ):
            raise BuildError(f"{label} entry path is not normalized")
        if entry["kind"] != "file" or entry["posixPermissions"] != 0o644:
            raise BuildError(f"{label} entry kind or permissions drifted")
        if isinstance(entry["size"], bool) or not isinstance(entry["size"], int) or entry["size"] < 0:
            raise BuildError(f"{label} entry size is invalid")
        if not _is_canonical_digest(entry["sha256"]):
            raise BuildError(f"{label} entry digest is not canonical")
        paths.append(path_value)
    if paths != sorted(paths) or len(paths) != len(set(paths)):
        raise BuildError(f"{label} entries are not sorted and unique")
    for required in ("Info.json", "main.js", "manifest.json"):
        if required not in paths:
            raise BuildError(f"{label} is missing {required}")
    manifest = next(entry for entry in entries if entry["path"] == "manifest.json")
    if manifest["sha256"] != catalog["contentManifestDigest"]:
        raise BuildError(f"{label} manifest digest mismatch")
    return catalog


def render_trust_history(history_dir: Path, current_catalog_bytes: bytes) -> bytes:
    current = validate_historical_catalog(
        load_json_bytes(current_catalog_bytes, "current catalog"),
        "current catalog metadata",
    )
    paths = sorted(history_dir.glob("*.catalog.json")) if history_dir.is_dir() else []
    if not paths:
        raise BuildError("historical catalog sources are missing")

    by_version: dict[str, dict] = {}
    for path in paths:
        catalog = validate_historical_catalog(
            load_json_bytes(read_required(path), str(path)),
            f"historical catalog {path.name}",
        )
        if path.name != f"{catalog['version']}.catalog.json":
            raise BuildError(f"historical catalog filename/version mismatch: {path.name}")
        previous = by_version.get(catalog["version"])
        if previous is not None and previous != catalog:
            raise BuildError(f"historical catalog version conflicts: {catalog['version']}")
        by_version[catalog["version"]] = catalog

    previous = by_version.get(current["version"])
    if previous is None:
        raise BuildError(
            f"current catalog {current['version']} must be retained as a versioned historical source"
        )
    if previous != current:
        raise BuildError(
            f"historical catalog for current version {current['version']} must be an exact retained copy"
        )
    catalogs = sorted(
        by_version.values(),
        key=lambda catalog: (catalog["version"], catalog["archive"]["sha256"]),
    )
    history = {
        "catalogs": catalogs,
        "identifier": EXPECTED_IDENTIFIER,
        "packageSchemaVersion": EXPECTED_PACKAGE_SCHEMA,
        "schemaVersion": TRUST_HISTORY_SCHEMA_VERSION,
    }
    return (json.dumps(history, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def validate_trust_history(
    trust_history_bytes: bytes,
    history_dir: Path,
    current_catalog_bytes: bytes,
) -> None:
    actual = load_json_bytes(trust_history_bytes, "anime4k.trusted-catalogs.json")
    expected = load_json_bytes(
        render_trust_history(history_dir, current_catalog_bytes),
        "expected trust history",
    )
    if actual != expected:
        raise BuildError("bundled trusted catalog history is stale or drifted")


def build_artifacts(source_dir: Path) -> tuple[bytes, bytes, bytes]:
    manifest, _info, shader_texts, manifest_bytes = validate_source(source_dir)
    bundle = render_bundle(manifest, shader_texts)
    decoded = decode_bundle(bundle)
    if decoded["manifest"] != manifest or decoded["shaders"] != shader_texts:
        raise BuildError("generated shader bundle does not decode to validated inputs")
    entries = package_entries(source_dir, bundle)
    validate_packaged_runtime_network_surface(entries)
    archive = build_archive(entries)
    validate_archive(archive, entries)
    catalog = render_catalog(archive, manifest_bytes)
    validate_catalog(catalog, archive, manifest_bytes)
    return bundle, archive, catalog


def check_artifacts(
    source_dir: Path,
    archive_path: Path,
    catalog_path: Path,
    history_dir: Path | None = None,
    trust_history_path: Path | None = None,
) -> None:
    expected_bundle, expected_archive, expected_catalog = build_artifacts(source_dir)
    bundle_path = source_dir / "lib" / "shader-bundle.js"
    actual_bundle = read_required(bundle_path)
    decoded = decode_bundle(actual_bundle)
    manifest = load_json_bytes(read_required(source_dir / "manifest.json"), "manifest.json")
    shader_texts = {
        shader_id: read_required(source_dir / "shaders" / filename).decode("utf-8")
        for shader_id, filename, *_rest in EXPECTED_SHADERS
    }
    if decoded["manifest"] != manifest or decoded["shaders"] != shader_texts:
        raise BuildError("committed shader bundle payload is stale")
    if actual_bundle != expected_bundle:
        raise BuildError("committed lib/shader-bundle.js is stale")

    actual_archive = read_required(archive_path)
    validate_archive(actual_archive, package_entries(source_dir, actual_bundle))
    if actual_archive != expected_archive:
        raise BuildError("committed anime4k.iinaplgz is stale or non-deterministic")

    actual_catalog = read_required(catalog_path)
    validate_catalog(actual_catalog, actual_archive, read_required(source_dir / "manifest.json"))
    if actual_catalog != expected_catalog:
        raise BuildError("committed anime4k.catalog.json is stale")

    history_dir = history_dir or source_dir / "trusted-catalogs"
    trust_history_path = trust_history_path or catalog_path.with_name("anime4k.trusted-catalogs.json")
    actual_history = read_required(trust_history_path)
    validate_trust_history(actual_history, history_dir, actual_catalog)
    if actual_history != render_trust_history(history_dir, actual_catalog):
        raise BuildError("committed anime4k.trusted-catalogs.json is stale")


def write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_bytes() == data:
        return
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary_name, 0o644)
        os.replace(temporary_name, path)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def parse_args(argv: list[str]) -> argparse.Namespace:
    repository = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify committed artifacts without writing")
    parser.add_argument("--source-dir", type=Path, default=repository / "deps/plugins-src/anime4k")
    parser.add_argument("--archive", type=Path, default=repository / "deps/plugins/anime4k.iinaplgz")
    parser.add_argument("--catalog", type=Path, default=repository / "deps/plugins/anime4k.catalog.json")
    parser.add_argument(
        "--history-dir",
        type=Path,
        default=repository / "deps/plugins-src/anime4k/trusted-catalogs",
    )
    parser.add_argument(
        "--trust-history",
        type=Path,
        default=repository / "deps/plugins/anime4k.trusted-catalogs.json",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        if args.check:
            check_artifacts(
                args.source_dir, args.archive, args.catalog,
                args.history_dir, args.trust_history,
            )
            print("Anime4K plugin artifacts are deterministic and current")
        else:
            bundle, archive, catalog = build_artifacts(args.source_dir)
            write_atomic(args.source_dir / "lib/shader-bundle.js", bundle)
            write_atomic(args.archive, archive)
            write_atomic(args.catalog, catalog)
            write_atomic(args.trust_history, render_trust_history(args.history_dir, catalog))
            check_artifacts(
                args.source_dir, args.archive, args.catalog,
                args.history_dir, args.trust_history,
            )
            print(f"Built {args.archive} ({len(archive)} bytes, sha256:{sha256(archive)})")
        return 0
    except BuildError as error:
        print(f"Anime4K package error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

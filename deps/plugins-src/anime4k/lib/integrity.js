"use strict";

var EXPECTED_IDENTIFIER = "io.iina.magnet.anime4k";
var EXPECTED_UPSTREAM_COMMIT = "7684e9586f8dcc738af08a1cdceb024cc184f426";
var MANIFEST_SCHEMA_VERSION = 1;

function fail(message) {
  throw new Error("Anime4K integrity: " + message);
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function ownKeysEqual(value, expected) {
  if (!isObject(value)) return false;
  var keys = Object.keys(value).sort();
  var wanted = expected.slice().sort();
  return keys.length === wanted.length && keys.every(function (key, index) {
    return key === wanted[index];
  });
}

function isFlatShaderFile(filename) {
  return typeof filename === "string" && filename.length > 5 &&
    filename.slice(-5) === ".glsl" && filename !== "." && filename !== ".." &&
    filename.indexOf("/") === -1 && filename.indexOf("\\") === -1;
}

function validateRecord(record, index, ids, files) {
  if (!ownKeysEqual(record, ["file", "id", "license", "order", "sha256", "size", "sourcePath"])) {
    fail("shader record " + index + " has an invalid schema");
  }
  if (typeof record.id !== "string" || !record.id) fail("shader record " + index + " has an invalid id");
  if (ids[record.id]) fail("duplicate shader id " + record.id);
  if (!isFlatShaderFile(record.file)) fail("shader " + record.id + " filename is not flat");
  if (files[record.file]) fail("duplicate shader filename " + record.file);
  if (record.order !== index) fail("shader " + record.id + " order is not canonical");
  if (typeof record.size !== "number" || record.size < 0 || Math.floor(record.size) !== record.size) {
    fail("shader " + record.id + " has an invalid UTF-8 size");
  }
  if (typeof record.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(record.sha256)) {
    fail("shader " + record.id + " has an invalid SHA-256");
  }
  ids[record.id] = true;
  files[record.file] = true;
}

function validatePresets(presets, ids) {
  if (!ownKeysEqual(presets, ["fast", "hq", "off"]) || !Array.isArray(presets.off) || presets.off.length) {
    fail("preset catalog schema drifted");
  }
  ["fast", "hq"].forEach(function (quality) {
    var catalog = presets[quality];
    var modes = ["A", "B", "C", "A+A", "B+B", "C+A"];
    if (!ownKeysEqual(catalog, modes)) fail(quality + " preset modes drifted");
    modes.forEach(function (mode) {
      var chain = catalog[mode];
      if (!Array.isArray(chain) || !chain.length) fail(quality + "/" + mode + " chain is empty");
      chain.forEach(function (id) {
        if (typeof id !== "string" || !ids[id]) fail(quality + "/" + mode + " references unknown shader " + id);
      });
    });
  });
}

function validateBundle(bundle, sha256) {
  if (!sha256 || typeof sha256.utf8Size !== "function" || typeof sha256.sha256Hex !== "function") {
    fail("SHA-256 adapter is unavailable");
  }
  if (!ownKeysEqual(bundle, ["manifest", "shaders"])) fail("bundle schema drifted");
  var manifest = bundle.manifest;
  if (!ownKeysEqual(manifest, ["plugin", "presets", "schemaVersion", "shaderBundleVersion", "shaders", "upstream"])) {
    fail("manifest schema drifted");
  }
  if (!isObject(manifest.plugin) || manifest.plugin.identifier !== EXPECTED_IDENTIFIER ||
      typeof manifest.plugin.version !== "string" || !manifest.plugin.version) {
    fail("plugin identity drifted");
  }
  if (manifest.schemaVersion !== MANIFEST_SCHEMA_VERSION ||
      typeof manifest.shaderBundleVersion !== "number" || manifest.shaderBundleVersion < 1 ||
      Math.floor(manifest.shaderBundleVersion) !== manifest.shaderBundleVersion) {
    fail("manifest version is unsupported");
  }
  if (!isObject(manifest.upstream) || manifest.upstream.commit !== EXPECTED_UPSTREAM_COMMIT ||
      manifest.upstream.repository !== "bloc97/Anime4K") {
    fail("upstream pin drifted");
  }
  if (!Array.isArray(manifest.shaders) || !manifest.shaders.length || !isObject(bundle.shaders)) {
    fail("shader payload is unavailable");
  }

  var ids = Object.create(null);
  var files = Object.create(null);
  manifest.shaders.forEach(function (record, index) { validateRecord(record, index, ids, files); });
  validatePresets(manifest.presets, ids);
  var payloadIds = Object.keys(bundle.shaders).sort();
  var manifestIds = Object.keys(ids).sort();
  if (payloadIds.length !== manifestIds.length || payloadIds.some(function (id, index) { return id !== manifestIds[index]; })) {
    fail("payload shader allow-list drifted");
  }
  manifest.shaders.forEach(function (record) {
    var content = bundle.shaders[record.id];
    if (typeof content !== "string") fail("payload " + record.id + " is not UTF-8 text");
    if (sha256.utf8Size(content) !== record.size) fail("payload size mismatch for " + record.file);
    if (sha256.sha256Hex(content) !== record.sha256) fail("payload SHA-256 mismatch for " + record.file);
  });
  return manifest;
}

function dataPath(version, filename) {
  if (!isFlatShaderFile(filename)) fail("refusing non-flat filename " + filename);
  return "@data/anime4k-v" + version + "--" + filename;
}

function markerPath(version) {
  return "@data/anime4k-v" + version + "--manifest.json";
}

function validBundleVersion(version) {
  return typeof version === "number" && version >= 1 && Math.floor(version) === version;
}

function validatedPriorMarkerFiles(text, version) {
  var marker;
  try {
    marker = JSON.parse(text);
  } catch (_error) {
    return null;
  }
  if (!ownKeysEqual(marker, ["schemaVersion", "shaderBundleVersion", "upstreamCommit", "files"]) ||
      marker.schemaVersion !== MANIFEST_SCHEMA_VERSION || marker.shaderBundleVersion !== version ||
      typeof marker.upstreamCommit !== "string" || !/^[0-9a-f]{40}$/.test(marker.upstreamCommit) ||
      !Array.isArray(marker.files) || !marker.files.length) return null;
  var seen = Object.create(null);
  var filenames = [];
  for (var index = 0; index < marker.files.length; index += 1) {
    var record = marker.files[index];
    if (!ownKeysEqual(record, ["file", "sha256", "size"]) || !isFlatShaderFile(record.file) ||
        seen[record.file] || typeof record.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(record.sha256) ||
        typeof record.size !== "number" || record.size < 0 || Math.floor(record.size) !== record.size) return null;
    seen[record.file] = true;
    filenames.push(record.file);
  }
  return filenames;
}

function derivePriorDataPaths(file, priorVersion, currentManifest) {
  var currentVersion = currentManifest && currentManifest.shaderBundleVersion;
  if (!validBundleVersion(priorVersion) || !validBundleVersion(currentVersion) || priorVersion === currentVersion) {
    return [];
  }
  var priorMarkerPath = markerPath(priorVersion);
  var filenames = null;
  try {
    if (file && typeof file.exists === "function" && typeof file.read === "function" && file.exists(priorMarkerPath)) {
      var markerText = file.read(priorMarkerPath, { encoding: "utf8" });
      if (typeof markerText === "string") filenames = validatedPriorMarkerFiles(markerText, priorVersion);
    }
  } catch (_error) {
    filenames = null;
  }
  if (!filenames) {
    filenames = [];
    var seen = Object.create(null);
    var records = currentManifest && Array.isArray(currentManifest.shaders) ? currentManifest.shaders : [];
    records.forEach(function (record) {
      if (record && isFlatShaderFile(record.file) && !seen[record.file]) {
        seen[record.file] = true;
        filenames.push(record.file);
      }
    });
  }
  return filenames.map(function (filename) { return dataPath(priorVersion, filename); }).concat([priorMarkerPath]);
}

function makeMarker(manifest) {
  return JSON.stringify({
    schemaVersion: MANIFEST_SCHEMA_VERSION,
    shaderBundleVersion: manifest.shaderBundleVersion,
    upstreamCommit: EXPECTED_UPSTREAM_COMMIT,
    files: manifest.shaders.map(function (record) {
      return { file: record.file, sha256: record.sha256, size: record.size };
    })
  });
}

function requireFileApi(file) {
  ["exists", "read", "write", "delete", "resolveLocal"].forEach(function (name) {
    if (!file || typeof file[name] !== "function") fail("file." + name + " is unavailable");
  });
}

function createManager(options) {
  options = options || {};
  requireFileApi(options.file);
  var file = options.file;
  var sha256 = options.sha256;
  var bundle = options.bundle;
  var manifest = validateBundle(bundle, sha256);
  var version = manifest.shaderBundleVersion;
  var records = manifest.shaders.map(function (record) {
    var virtualPath = dataPath(version, record.file);
    var localPath = file.resolveLocal(virtualPath);
    if (typeof localPath !== "string" || !localPath) fail("resolveLocal rejected " + virtualPath);
    return {
      id: record.id,
      file: record.file,
      size: record.size,
      sha256: record.sha256,
      content: bundle.shaders[record.id],
      virtualPath: virtualPath,
      localPath: localPath
    };
  });
  var byId = Object.create(null);
  records.forEach(function (record) { byId[record.id] = record; });
  var markerVirtualPath = markerPath(version);
  var markerLocalPath = file.resolveLocal(markerVirtualPath);
  if (typeof markerLocalPath !== "string" || !markerLocalPath) fail("resolveLocal rejected " + markerVirtualPath);
  var prior = Array.isArray(options.priorDataPaths) ? options.priorDataPaths.slice() : [];
  var currentVirtual = Object.create(null);
  records.forEach(function (record) { currentVirtual[record.virtualPath] = true; });
  currentVirtual[markerVirtualPath] = true;
  var priorRecords = prior.map(function (virtualPath) {
    if (typeof virtualPath !== "string" || !/^@data\/anime4k-v[1-9][0-9]*--[^/\\]+$/.test(virtualPath)) {
      fail("invalid explicit prior data path");
    }
    if (currentVirtual[virtualPath]) return null;
    var localPath = file.resolveLocal(virtualPath);
    if (typeof localPath !== "string" || !localPath) fail("resolveLocal rejected explicit prior path");
    return { virtualPath: virtualPath, localPath: localPath };
  }).filter(function (value) { return value !== null; });

  function valid(record) {
    if (!file.exists(record.virtualPath)) return false;
    try {
      var content = file.read(record.virtualPath, { encoding: "utf8" });
      return typeof content === "string" && sha256.utf8Size(content) === record.size &&
        sha256.sha256Hex(content) === record.sha256;
    } catch (_error) {
      return false;
    }
  }

  function validateMaterialized() {
    records.forEach(function (record) {
      if (!valid(record)) fail("materialized shader mismatch for " + record.file);
    });
    return true;
  }

  function ensureMaterialized() {
    var changed = false;
    records.forEach(function (record) {
      if (!valid(record)) {
        file.write(record.virtualPath, record.content);
        changed = true;
      }
    });
    validateMaterialized();
    priorRecords.forEach(function (record) {
      if (file.exists(record.virtualPath)) {
        file.delete(record.virtualPath);
        changed = true;
      }
    });
    var marker = makeMarker(manifest);
    var markerValid = false;
    if (file.exists(markerVirtualPath)) {
      try {
        markerValid = file.read(markerVirtualPath, { encoding: "utf8" }) === marker;
      } catch (_error) {
        markerValid = false;
      }
    }
    if (changed || !markerValid) file.write(markerVirtualPath, marker);
    return records.map(function (record) { return record.localPath; });
  }

  function pathsForIds(ids) {
    if (!Array.isArray(ids)) fail("preset chain must be an array");
    return ids.map(function (id) {
      if (!byId[id]) fail("preset references unknown shader " + id);
      return byId[id].localPath;
    });
  }

  return {
    manifest: manifest,
    markerVirtualPath: markerVirtualPath,
    markerLocalPath: markerLocalPath,
    records: records.slice(),
    ownedLocalPaths: records.map(function (record) { return record.localPath; }).concat(
      priorRecords.map(function (record) { return record.localPath; })
    ),
    ensureMaterialized: ensureMaterialized,
    validateMaterialized: validateMaterialized,
    pathsForIds: pathsForIds
  };
}

module.exports = {
  EXPECTED_IDENTIFIER: EXPECTED_IDENTIFIER,
  EXPECTED_UPSTREAM_COMMIT: EXPECTED_UPSTREAM_COMMIT,
  MANIFEST_SCHEMA_VERSION: MANIFEST_SCHEMA_VERSION,
  dataPath: dataPath,
  markerPath: markerPath,
  makeMarker: makeMarker,
  derivePriorDataPaths: derivePriorDataPaths,
  validateBundle: validateBundle,
  createManager: createManager
};

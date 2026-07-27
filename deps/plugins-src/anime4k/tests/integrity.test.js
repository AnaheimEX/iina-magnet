"use strict";

var test = require("node:test");
var assert = require("node:assert/strict");
var integrity = require("../lib/integrity.js");
var sha256 = require("../lib/sha256.js");

function bundleFor(text) {
  var id = "Shader_Unicode";
  var filename = "Shader Unicode.glsl";
  var chain = [id];
  return {
    manifest: {
      plugin: { identifier: integrity.EXPECTED_IDENTIFIER, version: "1.0.0" },
      presets: {
        fast: { A: chain, B: chain, C: chain, "A+A": chain, "B+B": chain, "C+A": chain },
        hq: { A: chain, B: chain, C: chain, "A+A": chain, "B+B": chain, "C+A": chain },
        off: []
      },
      schemaVersion: 1,
      shaderBundleVersion: 2,
      shaders: [{
        file: filename,
        id: id,
        license: "MIT",
        order: 0,
        sha256: sha256.sha256Hex(text),
        size: sha256.utf8Size(text),
        sourcePath: "fixture/" + filename
      }],
      upstream: {
        commit: integrity.EXPECTED_UPSTREAM_COMMIT,
        licenses: ["MIT"],
        repository: "bloc97/Anime4K"
      }
    },
    shaders: { Shader_Unicode: text }
  };
}

function fileFixture(initial) {
  var files = Object.assign({}, initial || {});
  var operations = [];
  return {
    files: files,
    operations: operations,
    exists: function (path) { return Object.prototype.hasOwnProperty.call(files, path); },
    read: function (path, options) {
      assert.deepEqual(options, { encoding: "utf8" });
      operations.push(["read", path]);
      if (!Object.prototype.hasOwnProperty.call(files, path)) throw new Error("missing " + path);
      return files[path];
    },
    write: function (path, content) {
      operations.push(["write", path]);
      files[path] = content;
    },
    delete: function (path) {
      operations.push(["delete", path]);
      delete files[path];
    },
    resolveLocal: function (path) {
      if (!/^@data\/[^/\\]+$/.test(path) || path.indexOf("..") !== -1) throw new Error("rejected path");
      return "/private/plugin data/" + path.slice(6);
    }
  };
}

test("bundle validation is pinned, flat, unique, and payload-integrity checked", function () {
  var valid = bundleFor("//!HOOK MAIN\r\n// 雪だるま ☃\n");
  assert.equal(integrity.validateBundle(valid, sha256).shaderBundleVersion, 2);

  var corrupt = bundleFor("ok\n");
  corrupt.shaders.Shader_Unicode = "changed\n";
  assert.throws(function () { integrity.validateBundle(corrupt, sha256); }, /payload (size|SHA-256) mismatch/);

  var traversal = bundleFor("ok\n");
  traversal.manifest.shaders[0].file = "../Shader.glsl";
  assert.throws(function () { integrity.validateBundle(traversal, sha256); }, /filename is not flat/);

  var duplicate = bundleFor("ok\n");
  var second = Object.assign({}, duplicate.manifest.shaders[0], { id: "Second", order: 1 });
  duplicate.manifest.shaders.push(second);
  duplicate.shaders.Second = "ok\n";
  assert.throws(function () { integrity.validateBundle(duplicate, sha256); }, /duplicate shader filename/);
});

test("materialization repairs missing and corrupt files and writes the verified marker last", function () {
  var bundle = bundleFor("//!HOOK MAIN\r\n// Unicode 雪\n");
  var path = integrity.dataPath(2, "Shader Unicode.glsl");
  var marker = integrity.markerPath(2);
  var file = fileFixture((function () {
    var value = {};
    value[path] = "corrupt";
    value[marker] = integrity.makeMarker(bundle.manifest);
    return value;
  }()));
  var originalRead = file.read;
  var unreadableOnce = true;
  file.read = function (virtualPath) {
    if (virtualPath === path && unreadableOnce) {
      unreadableOnce = false;
      throw new Error("invalid UTF-8 fixture");
    }
    return originalRead.apply(file, arguments);
  };
  var manager = integrity.createManager({ bundle: bundle, file: file, sha256: sha256 });
  assert.deepEqual(manager.ensureMaterialized(), ["/private/plugin data/anime4k-v2--Shader Unicode.glsl"]);
  assert.equal(file.files[path], bundle.shaders.Shader_Unicode);
  assert.equal(file.files[marker], integrity.makeMarker(bundle.manifest));
  assert.deepEqual(file.operations.filter(function (entry) { return entry[0] === "write"; }).map(function (entry) { return entry[1]; }), [path, marker]);
  assert.equal(manager.validateMaterialized(), true);

  file.operations.length = 0;
  manager.ensureMaterialized();
  assert.deepEqual(file.operations.filter(function (entry) { return entry[0] === "write"; }), []);
});

test("obsolete deletion is limited to an explicit prior exact list", function () {
  var bundle = bundleFor("current\n");
  var prior = "@data/anime4k-v1--Old.glsl";
  var similarlyNamed = "@data/anime4k-v1--Old.glsl.backup";
  var prefix = "@data/anime4k-v1--User.glsl";
  var file = fileFixture((function () {
    var value = {};
    value[prior] = "old";
    value[similarlyNamed] = "keep";
    value[prefix] = "keep";
    return value;
  }()));
  var manager = integrity.createManager({
    bundle: bundle,
    file: file,
    sha256: sha256,
    priorDataPaths: [prior]
  });
  manager.ensureMaterialized();
  assert.equal(file.exists(prior), false);
  assert.equal(file.files[similarlyNamed], "keep");
  assert.equal(file.files[prefix], "keep");
  var writesAndDeletes = file.operations.filter(function (entry) { return entry[0] !== "read"; });
  assert.equal(writesAndDeletes[writesAndDeletes.length - 1][1], integrity.markerPath(2));
});

test("prior version handoff trusts only a validated marker file list and otherwise uses an exact fallback", function () {
  var bundle = bundleFor("current\n");
  var marker = integrity.markerPath(1);
  var legacy = "@data/anime4k-v1--Legacy.glsl";
  var file = fileFixture((function () {
    var value = {};
    value[legacy] = "old";
    value[marker] = JSON.stringify({
      schemaVersion: 1,
      shaderBundleVersion: 1,
      upstreamCommit: "1".repeat(40),
      files: [{ file: "Legacy.glsl", sha256: "2".repeat(64), size: 3 }]
    });
    return value;
  }()));
  assert.deepEqual(integrity.derivePriorDataPaths(file, 1, bundle.manifest), [legacy, marker]);

  var manager = integrity.createManager({
    bundle: bundle,
    file: file,
    sha256: sha256,
    priorDataPaths: integrity.derivePriorDataPaths(file, 1, bundle.manifest)
  });
  assert.ok(manager.ownedLocalPaths.indexOf("/private/plugin data/anime4k-v1--Legacy.glsl") !== -1);
  manager.ensureMaterialized();
  assert.equal(file.exists(legacy), false);
  assert.equal(file.exists(marker), false);
  var firstDelete = file.operations.map(function (entry) { return entry[0]; }).indexOf("delete");
  var currentRead = file.operations.map(function (entry) { return entry.join("|"); }).lastIndexOf(
    "read|" + integrity.dataPath(2, "Shader Unicode.glsl")
  );
  assert.ok(firstDelete > currentRead);

  file = fileFixture((function () {
    var value = {};
    value[marker] = "corrupt";
    return value;
  }()));
  assert.deepEqual(integrity.derivePriorDataPaths(file, 1, bundle.manifest), [
    integrity.dataPath(1, "Shader Unicode.glsl"), marker
  ]);
  assert.deepEqual(integrity.derivePriorDataPaths(file, 2, bundle.manifest), []);
});

test("resolveLocal is mandatory and arbitrary prior paths fail closed", function () {
  var bundle = bundleFor("ok\n");
  var file = fileFixture();
  delete file.resolveLocal;
  assert.throws(function () {
    integrity.createManager({ bundle: bundle, file: file, sha256: sha256 });
  }, /file.resolveLocal is unavailable/);

  file = fileFixture();
  assert.throws(function () {
    integrity.createManager({
      bundle: bundle,
      file: file,
      sha256: sha256,
      priorDataPaths: ["@data/../not-owned.glsl"]
    });
  }, /invalid explicit prior data path/);
});

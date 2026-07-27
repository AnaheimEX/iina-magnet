"use strict";

var test = require("node:test");
var assert = require("node:assert/strict");
var fs = require("node:fs");
var path = require("node:path");
var vm = require("node:vm");
var runtimeModule = require("../lib/runtime.js");
var state = require("../lib/state.js");
var integrity = require("../lib/integrity.js");
var reconcile = require("../lib/reconcile.js");
var sha256 = require("../lib/sha256.js");
var telemetry = require("../lib/telemetry.js");

function bundleFixture(text, version) {
  var ids = ["Clamp", "Upscale"];
  var contents = { Clamp: text, Upscale: text + "// second\n" };
  var records = ids.map(function (id, index) {
    return {
      file: id + ".glsl",
      id: id,
      license: "MIT",
      order: index,
      sha256: sha256.sha256Hex(contents[id]),
      size: sha256.utf8Size(contents[id]),
      sourcePath: "fixture/" + id + ".glsl"
    };
  });
  function catalog(chain) {
    return { A: chain, B: chain.slice().reverse(), C: chain, "A+A": chain, "B+B": chain, "C+A": chain };
  }
  return {
    manifest: {
      plugin: { identifier: integrity.EXPECTED_IDENTIFIER, version: "1.0.0" },
      presets: { fast: catalog(ids), hq: catalog(ids.slice().reverse()), off: [] },
      schemaVersion: 1,
      shaderBundleVersion: version || 1,
      shaders: records,
      upstream: {
        commit: integrity.EXPECTED_UPSTREAM_COMMIT,
        licenses: ["MIT"],
        repository: "bloc97/Anime4K"
      }
    },
    shaders: contents
  };
}

function makeAdapters(preseed) {
  var files = {};
  var values = Object.assign({}, preseed || {});
  var handlers = {};
  var nextId = 1;
  var writes = [];
  var osd = [];
  var errors = [];
  var syncs = 0;
  var mpv = {
    value: [],
    getNative: function () { return mpv.value.slice(); },
    set: function (property, value) {
      assert.equal(property, "glsl-shaders");
      writes.push(value.slice());
      mpv.value = value.slice();
      if (typeof mpv.afterSet === "function") mpv.afterSet(value.slice());
    }
  };
  var event = {
    on: function (name, callback) {
      var id = String(nextId++);
      handlers[id] = { name: name, callback: callback };
      return id;
    },
    off: function (name, id) {
      if (handlers[id] && handlers[id].name === name) delete handlers[id];
    },
    emit: function (name, argument) {
      Object.keys(handlers).forEach(function (id) {
        if (handlers[id].name === name) handlers[id].callback(argument);
      });
    },
    count: function () { return Object.keys(handlers).length; }
  };
  return {
    adapters: {
      mpv: mpv,
      file: {
        exists: function (path) { return Object.prototype.hasOwnProperty.call(files, path); },
        read: function (path) {
          if (!Object.prototype.hasOwnProperty.call(files, path)) throw new Error("missing " + path);
          return files[path];
        },
        write: function (path, content) { files[path] = content; },
        delete: function (path) { delete files[path]; },
        resolveLocal: function (path) {
          if (!/^@data\/[^/\\]+$/.test(path) || path.indexOf("..") !== -1) throw new Error("unsafe path");
          return "/plugin data/" + path.slice(6);
        }
      },
      preferences: {
        get: function (key) { return values[key]; },
        set: function (key, value) { values[key] = value; },
        sync: function () { syncs += 1; }
      },
      event: event,
      osd: function (message) { osd.push(message); },
      console: { error: function (message) { errors.push(message); } }
    },
    mpv: mpv,
    files: files,
    values: values,
    event: event,
    writes: writes,
    osd: osd,
    errors: errors,
    syncs: function () { return syncs; }
  };
}

function create(fixture, bundle, extra) {
  extra = extra || {};
  return runtimeModule.createRuntime({
    adapters: fixture.adapters,
    modules: { state: state, integrity: integrity, reconcile: reconcile, sha256: sha256 },
    bundle: bundle,
    now: extra.now,
    failureOSDIntervalMs: extra.failureOSDIntervalMs
  });
}

function ownedPaths(bundle) {
  return bundle.manifest.shaders.map(function (record) {
    return "/plugin data/" + integrity.dataPath(bundle.manifest.shaderBundleVersion, record.file).slice(6);
  });
}

test("default-off start writes no mpv state; first enable applies Fast+A and persists", function () {
  var bundle = bundleFixture("//!HOOK MAIN\n");
  var fixture = makeAdapters();
  var runtime = create(fixture, bundle);
  assert.equal(runtime.start(), true);
  assert.equal(fixture.event.count(), 1);
  assert.deepEqual(fixture.writes, []);
  assert.equal(runtime.getState().mode, "off");
  assert.equal(runtime.getState().shaderBundleVersion, 1);
  assert.equal(fixture.values.shaderBundleVersion, 1);
  assert.equal(fixture.syncs(), 1);

  fixture.mpv.value = ["/user/keep.glsl"];
  assert.equal(runtime.enable(), true);
  assert.deepEqual(fixture.mpv.value, ["/user/keep.glsl"].concat(ownedPaths(bundle)));
  assert.equal(runtime.getState().mode, "A");
  assert.equal(runtime.getState().quality, "fast");
  assert.equal(fixture.values.mode, "A");
  assert.equal(fixture.syncs(), 2);
});

test("v1 to v2 start derives exact legacy ownership from marker and persists the bound version", function () {
  var bundle = bundleFixture("upgrade\n", 2);
  var fixture = makeAdapters({ shaderBundleVersion: 1 });
  var priorMarker = integrity.markerPath(1);
  var priorShader = integrity.dataPath(1, "Legacy.glsl");
  var unrelated = "@data/anime4k-v1--Legacy.glsl.backup";
  fixture.files[priorShader] = "old";
  fixture.files[unrelated] = "keep";
  fixture.files[priorMarker] = JSON.stringify({
    schemaVersion: 1,
    shaderBundleVersion: 1,
    upstreamCommit: "1".repeat(40),
    files: [{ file: "Legacy.glsl", sha256: "2".repeat(64), size: 3 }]
  });
  var priorLocal = "/plugin data/" + priorShader.slice(6);
  fixture.mpv.value = [priorLocal, "/user/keep.glsl"];

  var runtime = create(fixture, bundle);
  assert.equal(runtime.start(), true);
  assert.equal(runtime.getState().shaderBundleVersion, 2);
  assert.equal(fixture.values.shaderBundleVersion, 2);
  assert.equal(fixture.syncs(), 1);
  assert.equal(Object.prototype.hasOwnProperty.call(fixture.files, priorShader), false);
  assert.equal(Object.prototype.hasOwnProperty.call(fixture.files, priorMarker), false);
  assert.equal(fixture.files[unrelated], "keep");
  assert.equal(fixture.files[integrity.markerPath(2)], integrity.makeMarker(bundle.manifest));

  assert.equal(runtime.fileLoaded("local"), true);
  assert.deepEqual(fixture.mpv.value, ["/user/keep.glsl"]);
});

test("file-loaded treats local, HTTPS, and PikPak-like URLs identically", function () {
  var bundle = bundleFixture("same path\n");
  var fixture = makeAdapters({ mode: "A", quality: "hq", autoApply: true });
  var runtime = create(fixture, bundle);
  runtime.start();
  var urls = ["/Users/test/video.mkv", "https://cdn.example/video.mkv", "https://pikpak.example/d/file"];
  var results = [];
  urls.forEach(function (url) {
    fixture.mpv.value = ["/third party/雪: keep.glsl"];
    fixture.event.emit("iina.file-loaded", url);
    results.push(fixture.mpv.value.slice());
  });
  assert.deepEqual(results[0], results[1]);
  assert.deepEqual(results[1], results[2]);
  assert.deepEqual(results[0], ["/third party/雪: keep.glsl"].concat(ownedPaths(bundle).reverse()));
});

test("off or autoApply=false performs cleanup only when owned paths exist", function () {
  var bundle = bundleFixture("cleanup\n");
  var fixture = makeAdapters();
  var runtime = create(fixture, bundle);
  runtime.start();
  fixture.mpv.value = ["/user/a.glsl"];
  fixture.event.emit("iina.file-loaded", "local");
  assert.deepEqual(fixture.writes, []);

  fixture.mpv.value = ["/user/a.glsl", ownedPaths(bundle)[0], "/other/after.glsl"];
  fixture.event.emit("iina.file-loaded", "https://example.invalid/not-requested");
  assert.deepEqual(fixture.mpv.value, ["/user/a.glsl", "/other/after.glsl"]);

  var disabledFixture = makeAdapters({ mode: "A", quality: "fast", autoApply: false });
  var disabledRuntime = create(disabledFixture, bundle);
  disabledRuntime.start();
  disabledFixture.mpv.value = [ownedPaths(bundle)[1], "/keep"];
  disabledFixture.event.emit("iina.file-loaded", "pikpak://item");
  assert.deepEqual(disabledFixture.mpv.value, ["/keep"]);
});

test("missing/corrupt materialized files repair before apply", function () {
  var bundle = bundleFixture("repair me\n");
  var fixture = makeAdapters();
  var runtime = create(fixture, bundle);
  runtime.start();
  var first = integrity.dataPath(1, "Clamp.glsl");
  fixture.files[first] = "corrupt";
  delete fixture.files[integrity.dataPath(1, "Upscale.glsl")];
  assert.equal(runtime.enable(), true);
  assert.equal(fixture.files[first], bundle.shaders.Clamp);
  assert.equal(fixture.files[integrity.dataPath(1, "Upscale.glsl")], bundle.shaders.Upscale);
});

test("startup integrity failure immediately cleans exact ownership and stale cleanup cannot erase a newer selection", function () {
  var trusted = "startup cleanup\n";
  var bundle = bundleFixture(trusted);
  bundle.shaders.Clamp = "tampered\n";
  var fixture = makeAdapters();
  var owned = ownedPaths(bundle);
  var duplicate = "/third party/duplicate: 雪.glsl";
  var after = "/user/after.glsl";
  fixture.mpv.value = [duplicate, owned[0], duplicate, after, owned[1], after];
  var intervals = 0;
  var runtime = runtimeModule.createRuntime({
    adapters: fixture.adapters,
    modules: {
      state: state, integrity: integrity, reconcile: reconcile, sha256: sha256, telemetry: telemetry
    },
    bundle: bundle,
    setInterval: function () { intervals += 1; return "unexpected"; },
    clearInterval: function () {}
  });

  assert.equal(runtime.start(), true);
  assert.deepEqual(fixture.mpv.value, [duplicate, duplicate, after, after]);
  assert.deepEqual(fixture.writes, [[duplicate, duplicate, after, after]]);
  assert.equal(runtime.getState().mode, "off");
  assert.equal(runtime.getTelemetry(), null);
  assert.equal(intervals, 0);
  assert.equal(runtime.getDiagnostic().operation, "startup integrity");
  assert.match(runtime.getDiagnostic().error, /payload (size|SHA-256) mismatch/);
  assert.equal(runtime.getDiagnostic().cleanupError, null);

  var reentrantBundle = bundleFixture(trusted);
  reentrantBundle.shaders.Clamp = "tampered\n";
  var reentrantFixture = makeAdapters();
  var reentrantOwned = ownedPaths(reentrantBundle);
  reentrantFixture.mpv.value = [duplicate, reentrantOwned[0], duplicate, after];
  var reentrantRuntime = create(reentrantFixture, reentrantBundle);
  var originalGetNative = reentrantFixture.mpv.getNative;
  var reentered = false;
  reentrantFixture.mpv.getNative = function () {
    var staleSnapshot = originalGetNative();
    if (!reentered) {
      reentered = true;
      reentrantBundle.shaders.Clamp = trusted;
      assert.equal(reentrantRuntime.enable(), true);
    }
    return staleSnapshot;
  };

  assert.equal(reentrantRuntime.start(), true);
  assert.equal(reentered, true);
  assert.equal(reentrantRuntime.getState().mode, "A");
  assert.deepEqual(
    reentrantFixture.mpv.value,
    [duplicate, duplicate, after].concat(reentrantOwned)
  );
  assert.equal(reentrantFixture.writes.length, 1);
  assert.match(reentrantRuntime.getDiagnostic().cleanupError, /superseded/);
});

test("corrupt packaged payload and write/readback failures fail closed with operation-aware diagnostics", function () {
  var bundle = bundleFixture("trusted\n");
  bundle.shaders.Clamp = "tampered\n";
  var time = 1000;
  var fixture = makeAdapters({ mode: "A", quality: "fast", autoApply: true });
  fixture.mpv.value = ["/keep", ownedPaths(bundle)[0]];
  var runtime = create(fixture, bundle, { now: function () { return time; }, failureOSDIntervalMs: 100 });
  runtime.start();
  assert.equal(fixture.osd.length, 1);
  assert.equal(runtime.fileLoaded("first.mkv"), false);
  assert.equal(runtime.fileLoaded("second.mkv"), false);
  assert.equal(fixture.osd.length, 1);
  assert.equal(runtime.select("fast", "B"), false);
  assert.equal(runtime.select("fast", "C"), false);
  assert.deepEqual(fixture.mpv.value, ["/keep"]);
  assert.equal(fixture.osd.length, 3);
  assert.match(runtime.getDiagnostic().error, /payload (size|SHA-256) mismatch/);
  time += 101;
  runtime.fileLoaded("third.mkv");
  assert.equal(fixture.osd.length, 4);

  var goodBundle = bundleFixture("write failure\n");
  var writeFixture = makeAdapters();
  var goodRuntime = create(writeFixture, goodBundle);
  goodRuntime.start();
  writeFixture.mpv.value = ["/survives"];
  var originalSet = writeFixture.mpv.set;
  var failed = false;
  writeFixture.mpv.set = function (property, value) {
    if (!failed) { failed = true; throw new Error("injected mpv write"); }
    originalSet(property, value);
  };
  assert.equal(goodRuntime.enable(), false);
  assert.deepEqual(writeFixture.mpv.value, ["/survives"]);
  assert.match(goodRuntime.getDiagnostic().error, /injected mpv write/);
});

test("readback mismatch cleans exact owned paths from fresh latest state", function () {
  var bundle = bundleFixture("interleave\n");
  var fixture = makeAdapters();
  var runtime = create(fixture, bundle);
  runtime.start();
  fixture.mpv.value = ["/before"];
  var injected = false;
  fixture.mpv.afterSet = function () {
    if (!injected) {
      injected = true;
      fixture.mpv.value.push("/added after write: 雪.glsl");
    }
  };
  assert.equal(runtime.enable(), false);
  assert.deepEqual(fixture.mpv.value, ["/before", "/added after write: 雪.glsl"]);
  assert.match(runtime.getDiagnostic().error, /mismatch|verification|readback/i);
});

test("generation token prevents a stale reentrant operation from cleaning a newer selection", function () {
  var bundle = bundleFixture("generation\n");
  var fixture = makeAdapters();
  var runtime = create(fixture, bundle);
  runtime.start();
  fixture.mpv.value = ["/keep"];
  var reentered = false;
  fixture.mpv.afterSet = function () {
    if (!reentered) {
      reentered = true;
      assert.equal(runtime.select("hq", "B"), true);
    }
  };
  assert.equal(runtime.enable(), false);
  assert.equal(runtime.getState().mode, "B");
  assert.equal(runtime.getState().quality, "hq");
  assert.deepEqual(fixture.mpv.value, ["/keep"].concat(ownedPaths(bundle)));
  assert.equal(runtime.getDiagnostic(), null);
});

test("unload is synchronous/idempotent, unregisters the event, and cleans latest exact ownership", function () {
  var bundle = bundleFixture("unload\n");
  var fixture = makeAdapters();
  var runtime = create(fixture, bundle);
  runtime.start();
  fixture.mpv.value = ["/keep", ownedPaths(bundle)[0], "/latest"];
  var reentrantResults = [];
  fixture.mpv.afterSet = function () { reentrantResults.push(runtime.enable()); };
  assert.equal(runtime.unload(), true);
  assert.deepEqual(fixture.mpv.value, ["/keep", "/latest"]);
  assert.deepEqual(reentrantResults, [false]);
  assert.equal(fixture.event.count(), 0);
  var writeCount = fixture.writes.length;
  assert.equal(runtime.unload(), false);
  assert.equal(fixture.writes.length, writeCount);

  var replacement = create(fixture, bundle);
  replacement.start();
  assert.equal(fixture.event.count(), 1);
  fixture.event.emit("iina.file-loaded", "local");
  assert.equal(fixture.event.count(), 1);
});

test("OSD callback exceptions do not abort mode switch", function () {
  var bundle = bundleFixture("osd-failures\n");
  var fixture = makeAdapters();
  fixture.adapters.osd = function () {
    throw new Error("osd blocked");
  };
  fixture.mpv.value = ["/keep"];
  var runtime = create(fixture, bundle);
  runtime.start();
  fixture.mpv.value = ["/before"]; 
  assert.doesNotThrow(function () {
    assert.equal(runtime.enable(), true);
  }, "mode change must continue even if osd throws");
  assert.equal(runtime.getState().mode, "A");
  assert.equal(runtime.getState().quality, "fast");
});

test("core osd callback exceptions do not abort mode switch", function () {
  var bundle = bundleFixture("core-osd-failures\n");
  var fixture = makeAdapters();
  fixture.adapters.osd = undefined;
  fixture.adapters.core = {
    osd: function () {
      throw new Error("core-osd blocked");
    }
  };
  fixture.mpv.value = ["/keep"];
  var runtime = create(fixture, bundle);
  runtime.start();
  fixture.mpv.value = ["/before"];
  assert.doesNotThrow(function () {
    assert.equal(runtime.enable(), true);
  }, "core osd failure must not abort mode switch");
  assert.equal(runtime.getState().mode, "A");
  assert.equal(runtime.getState().quality, "fast");
});

test("entry wiring defines a synchronous global unload hook without CommonJS module", function () {
  var source = fs.readFileSync(path.join(__dirname, "..", "main.js"), "utf8");
  var starts = 0;
  var unloads = 0;
  var wiredRuntime = {
    start: function () { starts += 1; },
    unload: function () { unloads += 1; return true; }
  };
  var context = {
    iina: { mpv: {}, file: {}, preferences: {}, event: {}, core: {}, console: {} },
    require: function (request) {
      if (request === "./lib/runtime.js") {
        return { createRuntime: function () { return wiredRuntime; } };
      }
      return {};
    }
  };
  vm.runInNewContext(source, context, { filename: "main.js" });
  assert.equal(starts, 1);
  assert.equal(typeof context.iinaPluginWillUnload, "function");
  assert.equal(context.iinaPluginWillUnload(), true);
  assert.equal(unloads, 1);
});

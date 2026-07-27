"use strict";

var test = require("node:test");
var assert = require("node:assert/strict");
var runtimeModule = require("../lib/runtime.js");
var state = require("../lib/state.js");
var integrity = require("../lib/integrity.js");
var reconcile = require("../lib/reconcile.js");
var sha256 = require("../lib/sha256.js");
var shortcuts = require("../lib/shortcuts.js");
var telemetry = require("../lib/telemetry.js");

function bundleFixture() {
  var text = "//!HOOK MAIN\n";
  var record = { file: "Shader.glsl", id: "Shader", license: "MIT", order: 0,
    sha256: sha256.sha256Hex(text), size: sha256.utf8Size(text), sourcePath: "fixture/Shader.glsl" };
  var modes = { A: ["Shader"], B: ["Shader"], C: ["Shader"],
    "A+A": ["Shader"], "B+B": ["Shader"], "C+A": ["Shader"] };
  return {
    manifest: {
      plugin: { identifier: integrity.EXPECTED_IDENTIFIER, version: "1.0.0" },
      presets: { fast: modes, hq: modes, off: [] },
      schemaVersion: 1, shaderBundleVersion: 1, shaders: [record],
      upstream: { commit: integrity.EXPECTED_UPSTREAM_COMMIT, licenses: ["MIT"], repository: "bloc97/Anime4K" }
    },
    shaders: { Shader: text }
  };
}

function makeFixture(preferences, existingBindings) {
  var files = {};
  var values = Object.assign({}, preferences || {});
  var events = {};
  var eventId = 0;
  var osd = [];
  var menu = {
    items: [], removeCount: 0, forceCount: 0,
    item: function (title, action, options) {
      return { title: title, action: action, options: options || {}, items: [],
        addSubMenuItem: function (item) { this.items.push(item); return this; } };
    },
    separator: function () { return { separator: true }; },
    addItem: function (item) { menu.items.push(item); },
    removeAllItems: function () { menu.removeCount += 1; menu.items = []; },
    forceUpdate: function () { menu.forceCount += 1; }
  };
  var sidebar = {
    calls: [], handlers: {}, posts: [], shows: 0,
    loadFile: function (path) { sidebar.calls.push("load:" + path); sidebar.handlers = {}; },
    onMessage: function (name, callback) { sidebar.calls.push("on:" + name); sidebar.handlers[name] = callback; },
    postMessage: function (name, data) { sidebar.posts.push({ name: name, data: data }); },
    show: function () { sidebar.shows += 1; },
    emit: function (name, data) { return sidebar.handlers[name](data); }
  };
  var inputListeners = 0;
  var counters = { "frame-drop-count": 0, "mistimed-frame-count": 0,
    "vo-delayed-frame-count": 0, "estimated-vf-fps": 60 };
  var mpv = {
    shaders: [], counters: counters,
    getNative: function (name) { return name === "glsl-shaders" ? mpv.shaders.slice() : counters[name]; },
    set: function (name, value) { assert.equal(name, "glsl-shaders"); mpv.shaders = value.slice(); }
  };
  return {
    adapters: {
      mpv: mpv,
      file: {
        exists: function (path) { return Object.prototype.hasOwnProperty.call(files, path); },
        read: function (path) { return files[path]; },
        write: function (path, data) { files[path] = data; },
        delete: function (path) { delete files[path]; },
        resolveLocal: function (path) { return "/data/" + path.slice(6); }
      },
      preferences: { get: function (key) { return values[key]; }, set: function (key, value) { values[key] = value; }, sync: function () {} },
      event: {
        on: function (name, callback) { var id = String(++eventId); events[id] = { name: name, callback: callback }; return id; },
        off: function (name, id) { if (events[id] && events[id].name === name) delete events[id]; },
        emit: function (name, data) { Object.keys(events).forEach(function (id) {
          if (events[id].name === name) events[id].callback(data);
        }); }
      },
      menu: menu,
      input: {
        normalizeKeyCode: function (value) { return value; },
        getAllKeyBindings: function () { return existingBindings || {}; },
        onKeyDown: function () { inputListeners += 1; }
      },
      sidebar: sidebar,
      core: { window: { loaded: true }, osd: function (message) { osd.push(message); } },
      console: { error: function () {} }
    },
    values: values, menu: menu, sidebar: sidebar, osd: osd, mpv: mpv,
    inputListeners: function () { return inputListeners; }
  };
}

function create(fixture, options) {
  options = options || {};
  options.adapters = fixture.adapters;
  options.modules = { state: state, integrity: integrity, reconcile: reconcile,
    sha256: sha256, shortcuts: shortcuts, telemetry: telemetry };
  options.bundle = bundleFixture();
  return runtimeModule.createRuntime(options);
}

function item(menu, title) {
  return menu.items.filter(function (candidate) { return candidate.title === title; })[0];
}

test("menu/sidebar expose all controls and first activation hints exactly once", function () {
  var fixture = makeFixture();
  var runtime = create(fixture, { enableTelemetry: false });
  assert.equal(runtime.start(), true);
  assert.deepEqual(fixture.sidebar.calls, ["load:ui/sidebar.html", "on:anime4k.action"]);
  var postsBeforeHandshake = fixture.sidebar.posts.length;
  fixture.sidebar.emit("anime4k.action", { action: "state" });
  assert.equal(fixture.sidebar.posts.length, postsBeforeHandshake + 1);
  assert.ok(item(fixture.menu, "Quality"));
  assert.equal(item(fixture.menu, "Mode").items.length, 6);
  assert.ok(item(fixture.menu, "Show Shortcuts"));
  assert.ok(item(fixture.menu, "Repair Shader Bundle"));
  assert.ok(item(fixture.menu, "Diagnostics"));
  assert.equal(fixture.inputListeners(), 0);

  item(fixture.menu, "Mode").items[0].action();
  assert.equal(runtime.getState().mode, "A");
  assert.equal(runtime.getState().quality, "fast");
  assert.equal(runtime.getState().shortcutHintAcknowledged, true);
  assert.equal(fixture.osd.filter(function (message) { return /Anime4K shortcuts:/.test(message); }).length, 1);

  item(fixture.menu, "Mode").items[1].action();
  assert.equal(runtime.getState().mode, "B");
  assert.equal(fixture.osd.filter(function (message) { return /Anime4K shortcuts:/.test(message); }).length, 1);
  item(fixture.menu, "Show Shortcuts").action();
  assert.equal(fixture.osd.filter(function (message) { return /Anime4K shortcuts:/.test(message); }).length, 2);
  assert.equal(fixture.sidebar.shows, 1);
});

test("sidebar waits for window-loaded and then registers handlers after loadFile", function () {
  var fixture = makeFixture();
  fixture.adapters.core.window.loaded = false;
  var runtime = create(fixture, { enableTelemetry: false });
  runtime.start();
  assert.deepEqual(fixture.sidebar.calls, []);
  fixture.adapters.core.window.loaded = true;
  fixture.adapters.event.emit("iina.window-loaded");
  assert.deepEqual(fixture.sidebar.calls, ["load:ui/sidebar.html", "on:anime4k.action"]);
});

test("shortcut changes remove/rebuild/forceUpdate and clear stale accelerators", function () {
  var fixture = makeFixture({}, { "Meta+K": { key: "Meta+K", action: "other" } });
  var runtime = create(fixture, { enableTelemetry: false });
  runtime.start();
  var removeBefore = fixture.menu.removeCount;
  var forceBefore = fixture.menu.forceCount;
  assert.equal(runtime.updateShortcuts({ off: "", A: "Meta+K", B: "Bogus+" }), false);
  assert.equal(fixture.menu.removeCount, removeBefore + 1);
  assert.equal(fixture.menu.forceCount, forceBefore + 1);
  assert.equal(item(fixture.menu, "Off").options.keyBinding, undefined);
  assert.equal(item(fixture.menu, "Mode").items[0].options.keyBinding, undefined);
  assert.equal(item(fixture.menu, "Mode").items[1].options.keyBinding, undefined);
  assert.equal(fixture.values.shortcuts.off, "");
  assert.ok(runtime.getShortcutValidation().issues.length >= 2);
  assert.match(fixture.osd.join("\n"), /shortcut conflict/);
  assert.equal(fixture.inputListeners(), 0);
});

test("sidebar actions, menu, and OSD stay synchronized", function () {
  var fixture = makeFixture();
  var runtime = create(fixture, { enableTelemetry: false });
  runtime.start();
  fixture.sidebar.emit("anime4k.action", { action: "quality", quality: "hq" });
  fixture.sidebar.emit("anime4k.action", { action: "mode", mode: "C+A" });
  assert.equal(runtime.getState().quality, "hq");
  assert.equal(runtime.getState().mode, "C+A");
  assert.match(fixture.osd.join("\n"), /Anime4K: HQ · Mode C\+A/);
  var latest = fixture.sidebar.posts.filter(function (post) { return post.name === "anime4k.state"; }).pop();
  assert.equal(latest.data.mode, "C+A");
  assert.equal(item(fixture.menu, "Mode").items[5].options.selected, true);
});

test("HQ/double-pass warning is rate-limited and never mutates selection", function () {
  var time = 1000;
  var fixture = makeFixture();
  var runtime = create(fixture, { enableTelemetry: false, now: function () { return time; }, heavyWarningIntervalMs: 60000 });
  runtime.start();
  runtime.select("hq", "B+B");
  runtime.select("hq", "B+B");
  assert.equal(fixture.osd.filter(function (message) { return /GPU intensive/.test(message); }).length, 1);
  time += 60001;
  runtime.select("hq", "B+B");
  assert.equal(fixture.osd.filter(function (message) { return /GPU intensive/.test(message); }).length, 2);
  assert.equal(runtime.getState().mode, "B+B");
  assert.equal(runtime.getState().quality, "hq");
});

function fakeClock() {
  var time = 0;
  var next = 0;
  var tasks = {};
  var created = 0;
  function interval(callback, delay) {
    var id = String(++next);
    created += 1;
    tasks[id] = { at: time + delay, callback: callback, interval: delay };
    return id;
  }
  function cancel(id) { delete tasks[id]; }
  function advance(milliseconds) {
    var target = time + milliseconds;
    while (true) {
      var due = Object.keys(tasks).filter(function (id) { return tasks[id].at <= target; })
        .sort(function (left, right) { return tasks[left].at - tasks[right].at; })[0];
      if (!due) break;
      var task = tasks[due];
      time = task.at;
      task.callback();
      if (tasks[due] === task) task.at += task.interval;
    }
    time = target;
  }
  return {
    now: function () { return time; }, interval: interval, cancel: cancel, advance: advance,
    activeCount: function () { return Object.keys(tasks).length; },
    createdCount: function () { return created; }
  };
}

test("runtime waits 10s, samples every 2s, warns after three overload windows, and never auto-switches", function () {
  var clock = fakeClock();
  var fixture = makeFixture({ mode: "A", quality: "fast", autoApply: true, shortcutHintAcknowledged: true });
  var runtime = create(fixture, { now: clock.now, setInterval: clock.interval, clearInterval: clock.cancel,
    telemetryWarmupMs: 10000, telemetrySampleMs: 2000 });
  runtime.start();
  runtime.fileLoaded("https://pikpak.example/file");
  assert.equal(clock.activeCount(), 1);
  assert.equal(clock.createdCount(), 1);
  clock.advance(10000);
  [2, 4, 6].forEach(function (drops) {
    fixture.mpv.counters["frame-drop-count"] = drops;
    clock.advance(2000);
  });
  assert.equal(fixture.osd.filter(function (message) { return /sustained frame pressure/.test(message); }).length, 1);
  assert.equal(runtime.getState().mode, "A");
  assert.equal(runtime.getState().quality, "fast");
  assert.equal(clock.activeCount(), 1);
  assert.equal(clock.createdCount(), 1);
  assert.equal(runtime.getTelemetry().fps, 60);
  assert.equal(runtime.getTelemetry().adverse, 2);
  assert.equal(runtime.getTelemetry().denominator, 120);
  assert.equal(runtime.getTelemetry().ratio, 2 / 120);
  assert.equal(runtime.getTelemetry().consecutive, 3);
  assert.equal(runtime.getTelemetry().frameBudgetMs, 1000 / 60);
  runtime.showDiagnostics();
  var diagnostics = fixture.sidebar.posts.filter(function (post) {
    return post.name === "anime4k.diagnostics";
  }).pop();
  assert.equal(diagnostics.data.telemetry.frameBudgetMs, 1000 / 60);

  fixture.mpv.counters["mistimed-frame-count"] = "unavailable";
  runtime.fileLoaded("/Users/local/new-file.mkv");
  assert.equal(clock.activeCount(), 1);
  assert.equal(clock.createdCount(), 2);
  clock.advance(10000);
  assert.equal(runtime.getTelemetry().status, "disabled");
  assert.equal(runtime.getState().mode, "A");
  assert.equal(clock.activeCount(), 0);

  fixture.mpv.counters["mistimed-frame-count"] = 0;
  runtime.fileLoaded("/Users/local/third-file.mkv");
  assert.equal(clock.activeCount(), 1);
  assert.equal(clock.createdCount(), 3);
  runtime.disable();
  assert.equal(clock.activeCount(), 0);
  runtime.select("fast", "A");
  assert.equal(clock.activeCount(), 1);
  assert.equal(clock.createdCount(), 4);
  runtime.unload();
  assert.equal(clock.activeCount(), 0);
});

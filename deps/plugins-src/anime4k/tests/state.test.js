"use strict";

var test = require("node:test");
var assert = require("node:assert/strict");
var state = require("../lib/state.js");

test("default and invalid preferences remain safely off", function () {
  var empty = state.migrate({});
  assert.equal(empty.mode, "off");
  assert.equal(empty.quality, "fast");
  assert.equal(empty.autoApply, true);
  assert.equal(empty.shaderBundleVersion, 1);
  assert.equal(empty.shortcutHintAcknowledged, false);
  assert.equal(empty.lastMode, "A");
  assert.equal(empty.lastQuality, "fast");

  var invalid = state.migrate({ mode: "surprise", quality: "ultra", hasActivated: true, shaderBundleVersion: 0 });
  assert.equal(invalid.mode, "off");
  assert.equal(invalid.quality, "fast");
  assert.equal(invalid.lastMode, "A");
  assert.equal(invalid.shaderBundleVersion, 1);
});

test("legacy state imports valid selections and migration is idempotent", function () {
  var legacy = state.migrate({ mode: "B+B", quality: "hq", autoApply: false });
  assert.equal(legacy.mode, "B+B");
  assert.equal(legacy.quality, "hq");
  assert.equal(legacy.hasActivated, true);
  assert.equal(legacy.lastMode, "B+B");
  assert.equal(legacy.lastQuality, "hq");
  assert.deepEqual(state.migrate(legacy), legacy);
});

test("first enable is Fast+A and later enable restores last non-off selection", function () {
  var first = state.enable(state.defaultState());
  assert.equal(first.mode, "A");
  assert.equal(first.quality, "fast");
  var chosen = state.select(first, "hq", "C+A");
  var disabled = state.disable(chosen);
  assert.equal(disabled.mode, "off");
  var restored = state.enable(disabled);
  assert.equal(restored.mode, "C+A");
  assert.equal(restored.quality, "hq");
});

test("preference read/write persists every runtime state key", function () {
  var storage = {};
  var syncs = 0;
  var preferences = {
    get: function (key) { return storage[key]; },
    set: function (key, value) { storage[key] = value; },
    sync: function () { syncs += 1; }
  };
  var selected = state.select(state.defaultState(), "hq", "B");
  assert.deepEqual(state.writePreferences(preferences, selected), selected);
  assert.equal(syncs, 1);
  assert.deepEqual(state.readPreferences(preferences), selected);
});

test("quality, autoApply, shortcut disable, and hint acknowledgement persist", function () {
  var current = state.defaultState();
  current = state.setQuality(current, "hq");
  current = state.setAutoApply(current, false);
  current = state.setShortcuts(current, Object.assign({}, current.shortcuts, { A: "", B: "Alt+K" }));
  current = state.acknowledgeShortcuts(current);
  current = state.setShaderBundleVersion(current, 2);
  assert.equal(current.mode, "off");
  assert.equal(current.quality, "hq");
  assert.equal(current.autoApply, false);
  assert.equal(current.shortcuts.A, "");
  assert.equal(current.shortcuts.B, "Alt+K");
  assert.equal(current.shortcutHintAcknowledged, true);
  assert.equal(current.shaderBundleVersion, 2);
  assert.deepEqual(state.migrate(current), current);
  assert.throws(function () { state.setShaderBundleVersion(current, 1.5); }, /positive integer/);
});

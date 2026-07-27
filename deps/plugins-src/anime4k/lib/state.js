"use strict";

var SCHEMA_VERSION = 1;
var DEFAULT_SHADER_BUNDLE_VERSION = 1;
var MODES = ["off", "A", "B", "C", "A+A", "B+B", "C+A"];
var NON_OFF_MODES = MODES.slice(1);
var QUALITIES = ["fast", "hq"];
var SHORTCUTS = {
  off: "Ctrl+0", A: "Ctrl+1", B: "Ctrl+2", C: "Ctrl+3",
  "A+A": "Ctrl+4", "B+B": "Ctrl+5", "C+A": "Ctrl+6",
  fast: "Ctrl+7", hq: "Ctrl+8"
};
var PREFERENCE_KEYS = [
  "schemaVersion", "shaderBundleVersion", "mode", "quality", "autoApply", "hasActivated",
  "lastMode", "lastQuality", "shortcutHintAcknowledged", "shortcuts"
];

function contains(array, value) {
  return array.indexOf(value) !== -1;
}

function copyObject(value) {
  var result = {};
  Object.keys(value || {}).forEach(function (key) { result[key] = value[key]; });
  return result;
}

function shortcutsEqual(left, right) {
  var keys = Object.keys(SHORTCUTS);
  if (!left || !right || Object.keys(left).length !== keys.length || Object.keys(right).length !== keys.length) {
    return false;
  }
  return keys.every(function (key) { return left[key] === right[key]; });
}

function normalizeShortcuts(value) {
  var result = copyObject(SHORTCUTS);
  if (!value || typeof value !== "object" || Array.isArray(value)) return result;
  Object.keys(SHORTCUTS).forEach(function (key) {
    if (Object.prototype.hasOwnProperty.call(value, key) && typeof value[key] === "string") {
      result[key] = value[key];
    }
  });
  return result;
}

function defaultState() {
  return {
    schemaVersion: SCHEMA_VERSION,
    shaderBundleVersion: DEFAULT_SHADER_BUNDLE_VERSION,
    mode: "off",
    quality: "fast",
    autoApply: true,
    hasActivated: false,
    lastMode: "A",
    lastQuality: "fast",
    shortcutHintAcknowledged: false,
    shortcuts: copyObject(SHORTCUTS)
  };
}

function migrate(raw) {
  raw = raw && typeof raw === "object" ? raw : {};
  var state = defaultState();
  var validMode = contains(MODES, raw.mode) ? raw.mode : "off";
  var validQuality = contains(QUALITIES, raw.quality) ? raw.quality : "fast";
  var validShaderBundleVersion = typeof raw.shaderBundleVersion === "number" &&
    raw.shaderBundleVersion >= 1 && Math.floor(raw.shaderBundleVersion) === raw.shaderBundleVersion ?
    raw.shaderBundleVersion : DEFAULT_SHADER_BUNDLE_VERSION;

  state.shaderBundleVersion = validShaderBundleVersion;
  state.mode = validMode;
  state.quality = validQuality;
  state.autoApply = typeof raw.autoApply === "boolean" ? raw.autoApply : true;
  state.hasActivated = typeof raw.hasActivated === "boolean" ? raw.hasActivated : validMode !== "off";
  state.lastMode = contains(NON_OFF_MODES, raw.lastMode) ? raw.lastMode : (validMode !== "off" ? validMode : "A");
  state.lastQuality = contains(QUALITIES, raw.lastQuality) ? raw.lastQuality : validQuality;
  state.shortcutHintAcknowledged = typeof raw.shortcutHintAcknowledged === "boolean" ? raw.shortcutHintAcknowledged : false;
  state.shortcuts = normalizeShortcuts(raw.shortcuts);

  if (state.mode !== "off") {
    state.hasActivated = true;
    state.lastMode = state.mode;
    state.lastQuality = state.quality;
  }
  return state;
}

function equal(left, right) {
  return left.schemaVersion === right.schemaVersion &&
    left.shaderBundleVersion === right.shaderBundleVersion && left.mode === right.mode &&
    left.quality === right.quality && left.autoApply === right.autoApply &&
    left.hasActivated === right.hasActivated && left.lastMode === right.lastMode &&
    left.lastQuality === right.lastQuality &&
    left.shortcutHintAcknowledged === right.shortcutHintAcknowledged &&
    shortcutsEqual(left.shortcuts, right.shortcuts);
}

function enable(current) {
  var next = migrate(current);
  if (next.mode !== "off") return next;
  if (!next.hasActivated) {
    next.quality = "fast";
    next.mode = "A";
  } else {
    next.quality = next.lastQuality;
    next.mode = next.lastMode;
  }
  next.hasActivated = true;
  next.lastQuality = next.quality;
  next.lastMode = next.mode;
  return next;
}

function select(current, quality, mode) {
  var next = migrate(current);
  if (!contains(QUALITIES, quality)) throw new Error("Invalid Anime4K quality: " + quality);
  if (!contains(MODES, mode)) throw new Error("Invalid Anime4K mode: " + mode);
  next.quality = quality;
  next.mode = mode;
  if (mode !== "off") {
    next.hasActivated = true;
    next.lastQuality = quality;
    next.lastMode = mode;
  }
  return next;
}

function disable(current) {
  var next = migrate(current);
  if (next.mode !== "off") {
    next.lastMode = next.mode;
    next.lastQuality = next.quality;
  }
  next.mode = "off";
  return next;
}

function setQuality(current, quality) {
  var next = migrate(current);
  if (!contains(QUALITIES, quality)) throw new Error("Invalid Anime4K quality: " + quality);
  next.quality = quality;
  next.lastQuality = quality;
  return next;
}

function setAutoApply(current, enabled) {
  var next = migrate(current);
  if (typeof enabled !== "boolean") throw new Error("Anime4K autoApply must be boolean");
  next.autoApply = enabled;
  return next;
}

function setShortcuts(current, shortcuts) {
  var next = migrate(current);
  next.shortcuts = normalizeShortcuts(shortcuts);
  return next;
}

function setShaderBundleVersion(current, version) {
  if (typeof version !== "number" || version < 1 || Math.floor(version) !== version) {
    throw new Error("Anime4K shaderBundleVersion must be a positive integer");
  }
  var next = migrate(current);
  next.shaderBundleVersion = version;
  return next;
}

function acknowledgeShortcuts(current) {
  var next = migrate(current);
  next.shortcutHintAcknowledged = true;
  return next;
}

function readPreferences(preferences) {
  var raw = {};
  PREFERENCE_KEYS.forEach(function (key) { raw[key] = preferences.get(key); });
  return migrate(raw);
}

function writePreferences(preferences, state) {
  var normalized = migrate(state);
  PREFERENCE_KEYS.forEach(function (key) { preferences.set(key, normalized[key]); });
  if (typeof preferences.sync === "function") preferences.sync();
  return normalized;
}

module.exports = {
  SCHEMA_VERSION: SCHEMA_VERSION,
  DEFAULT_SHADER_BUNDLE_VERSION: DEFAULT_SHADER_BUNDLE_VERSION,
  MODES: MODES.slice(),
  NON_OFF_MODES: NON_OFF_MODES.slice(),
  QUALITIES: QUALITIES.slice(),
  SHORTCUTS: copyObject(SHORTCUTS),
  PREFERENCE_KEYS: PREFERENCE_KEYS.slice(),
  defaultState: defaultState,
  migrate: migrate,
  equal: equal,
  enable: enable,
  select: select,
  disable: disable,
  setQuality: setQuality,
  setAutoApply: setAutoApply,
  setShortcuts: setShortcuts,
  setShaderBundleVersion: setShaderBundleVersion,
  acknowledgeShortcuts: acknowledgeShortcuts,
  readPreferences: readPreferences,
  writePreferences: writePreferences
};

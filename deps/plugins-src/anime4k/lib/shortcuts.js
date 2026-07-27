"use strict";

var ACTIONS = ["off", "A", "B", "C", "A+A", "B+B", "C+A", "fast", "hq"];
var LABELS = {
  off: "Off", A: "Mode A", B: "Mode B", C: "Mode C",
  "A+A": "Mode A+A", "B+B": "Mode B+B", "C+A": "Mode C+A",
  fast: "Fast", hq: "HQ"
};
var SPECIAL_KEYS = Object.create(null);
[
  "LEFT", "RIGHT", "UP", "DOWN", "BS", "KP_DEL", "TAB", "DEL", "KP_INS", "INS",
  "HOME", "END", "PGUP", "PGDWN", "PRINT", "SPACE", "IDEOGRAPHIC_SPACE", "SHARP",
  "ENTER", "ESC", "KP_DEC", "KP_ENTER", "KP0", "KP1", "KP2", "KP3", "KP4", "KP5",
  "KP6", "KP7", "KP8", "KP9", "PLUS"
].forEach(function (key) { SPECIAL_KEYS[key] = true; });
for (var functionKey = 1; functionKey <= 12; functionKey += 1) SPECIAL_KEYS["F" + functionKey] = true;

function own(object, key) {
  return Object.prototype.hasOwnProperty.call(object || {}, key);
}

function syntax(normalize, value) {
  if (typeof value !== "string") return { ok: false, reason: "must be a string" };
  var trimmed = value.replace(/^\s+|\s+$/g, "");
  if (!trimmed) return { ok: true, normalized: "", disabled: true };
  var normalized;
  try {
    normalized = normalize(trimmed);
  } catch (error) {
    return { ok: false, reason: "normalization failed" };
  }
  if (typeof normalized !== "string" || !normalized || /\s/.test(normalized) || normalized.indexOf("-") !== -1) {
    return { ok: false, reason: "invalid key binding" };
  }
  var parts = normalized.split("+");
  var key = parts.pop();
  var seen = {};
  if (!key || (key.length !== 1 && !SPECIAL_KEYS[key])) {
    return { ok: false, reason: "invalid regular key" };
  }
  for (var index = 0; index < parts.length; index += 1) {
    var modifier = parts[index];
    if (["Ctrl", "Alt", "Shift", "Meta"].indexOf(modifier) === -1 || seen[modifier]) {
      return { ok: false, reason: "invalid or duplicate modifier" };
    }
    seen[modifier] = true;
  }
  return { ok: true, normalized: normalized, disabled: false };
}

function validate(shortcuts, input) {
  shortcuts = shortcuts || {};
  input = input || {};
  var normalize = typeof input.normalizeKeyCode === "function" ?
    function (value) { return input.normalizeKeyCode(value); } : function (value) { return value; };
  var existing = typeof input.getAllKeyBindings === "function" ? input.getAllKeyBindings() : {};
  existing = existing && typeof existing === "object" ? existing : {};
  var existingNormalized = {};
  Object.keys(existing).forEach(function (key) {
    var record = existing[key];
    var candidate = record && typeof record.key === "string" ? record.key : key;
    var result = syntax(normalize, candidate);
    if (result.ok && !result.disabled) existingNormalized[result.normalized] = true;
  });

  var parsed = {};
  var owners = {};
  var bindings = {};
  var stored = {};
  var issues = [];
  ACTIONS.forEach(function (action) {
    var raw = own(shortcuts, action) ? shortcuts[action] : "";
    var result = syntax(normalize, raw);
    parsed[action] = result;
    stored[action] = result.ok ? result.normalized : (typeof raw === "string" ? raw : "");
    if (result.ok && !result.disabled) {
      if (!owners[result.normalized]) owners[result.normalized] = [];
      owners[result.normalized].push(action);
    }
  });

  ACTIONS.forEach(function (action) {
    var result = parsed[action];
    bindings[action] = null;
    if (!result.ok) {
      issues.push({ action: action, binding: stored[action], reason: result.reason });
    } else if (!result.disabled && owners[result.normalized].length > 1) {
      issues.push({ action: action, binding: result.normalized, reason: "duplicate Anime4K binding" });
    } else if (!result.disabled && existingNormalized[result.normalized]) {
      issues.push({ action: action, binding: result.normalized, reason: "conflicts with an existing IINA/mpv binding" });
    } else if (!result.disabled) {
      bindings[action] = result.normalized;
    }
  });
  return { bindings: bindings, stored: stored, issues: issues };
}

function hintLines(validation) {
  return ACTIONS.map(function (action) {
    return (validation.bindings[action] || "Unassigned") + " — " + LABELS[action];
  });
}

module.exports = {
  ACTIONS: ACTIONS.slice(),
  LABELS: LABELS,
  SPECIAL_KEYS: Object.keys(SPECIAL_KEYS).sort(),
  syntax: syntax,
  validate: validate,
  hintLines: hintLines
};

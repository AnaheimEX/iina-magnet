"use strict";

var test = require("node:test");
var assert = require("node:assert/strict");
var shortcuts = require("../lib/shortcuts.js");

function input(existing) {
  return {
    normalizeKeyCode: function (value) {
      var parts = value.split("+");
      var key = parts.pop().toUpperCase();
      var order = ["Ctrl", "Alt", "Shift", "Meta"];
      var modifiers = parts.map(function (part) {
        var lower = part.toLowerCase();
        return lower === "control" || lower === "ctrl" ? "Ctrl" :
          lower === "option" || lower === "alt" ? "Alt" :
          lower === "command" || lower === "meta" ? "Meta" :
          lower === "shift" ? "Shift" : part;
      }).sort(function (left, right) { return order.indexOf(left) - order.indexOf(right); });
      return modifiers.concat([key]).join("+");
    },
    getAllKeyBindings: function () { return existing || {}; }
  };
}

var defaults = {
  off: "Ctrl+0", A: "Ctrl+1", B: "Ctrl+2", C: "Ctrl+3",
  "A+A": "Ctrl+4", "B+B": "Ctrl+5", "C+A": "Ctrl+6",
  fast: "Ctrl+7", hq: "Ctrl+8"
};

test("Ctrl+0...8 defaults normalize and remain assignable", function () {
  var result = shortcuts.validate(defaults, input());
  assert.deepEqual(result.issues, []);
  assert.deepEqual(result.bindings, defaults);
  assert.equal(shortcuts.hintLines(result).length, 9);
  assert.match(shortcuts.hintLines(result)[0], /Ctrl\+0.*Off/);
});

test("invalid, duplicate, disabled, and existing bindings install no accelerator", function () {
  var configured = Object.assign({}, defaults, {
    off: "",
    A: "Ctrl+X",
    B: "control+x",
    C: "Bogus+",
    fast: "Meta+K"
  });
  var result = shortcuts.validate(configured, input({ "Meta+K": { key: "Meta+K" } }));
  assert.equal(result.bindings.off, null);
  assert.equal(result.bindings.A, null);
  assert.equal(result.bindings.B, null);
  assert.equal(result.bindings.C, null);
  assert.equal(result.bindings.fast, null);
  assert.match(result.issues.map(function (issue) { return issue.reason; }).join("\n"), /duplicate Anime4K/);
  assert.match(result.issues.map(function (issue) { return issue.reason; }).join("\n"), /existing IINA\/mpv/);
  assert.match(result.issues.map(function (issue) { return issue.reason; }).join("\n"), /invalid/);
});

test("custom valid bindings are canonicalized for persistence", function () {
  var result = shortcuts.validate(Object.assign({}, defaults, { A: "alt+shift+k" }), input());
  assert.equal(result.bindings.A, "Alt+Shift+K");
  assert.equal(result.stored.A, "Alt+Shift+K");
});

test("only host-mappable multi-character special keys are accepted", function () {
  assert.equal(shortcuts.syntax(function (value) { return value; }, "Ctrl+BOGUS").ok, false);
  shortcuts.SPECIAL_KEYS.forEach(function (key) {
    var result = shortcuts.syntax(function (value) { return value; }, "Ctrl+" + key);
    assert.equal(result.ok, true, key);
    assert.equal(result.normalized, "Ctrl+" + key);
  });
  assert.equal(shortcuts.syntax(function (value) { return value; }, "Meta+K").ok, true);
});

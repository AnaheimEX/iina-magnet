"use strict";

var assert = require("node:assert/strict");
var fs = require("node:fs");
var path = require("node:path");
var test = require("node:test");
var vm = require("node:vm");

var ROOT = path.join(__dirname, "..");

function element(id) {
  var value = {
    id: id || null,
    children: [],
    dataset: {},
    hidden: false,
    value: "",
    checked: false,
    listeners: {},
    classList: { toggle: function () {} },
    appendChild: function (child) { this.children.push(child); },
    addEventListener: function (name, callback) { this.listeners[name] = callback; }
  };
  var text = "";
  Object.defineProperty(value, "textContent", {
    get: function () { return text; },
    set: function (next) {
      text = String(next);
      if (next === "") this.children = [];
    }
  });
  return value;
}

function fixture() {
  var ids = [
    "status", "auto-apply", "shortcut-fields", "shortcut-issues", "off",
    "save-shortcuts", "show-shortcuts", "repair", "diagnostics", "hint", "diagnostic-output"
  ];
  var elements = {};
  ids.forEach(function (id) { elements[id] = element(id); });
  var qualities = ["fast", "hq"].map(function (quality) {
    var button = element();
    button.dataset.quality = quality;
    return button;
  });
  var modes = ["A", "B", "C", "A+A", "B+B", "C+A"].map(function (mode) {
    var button = element();
    button.dataset.mode = mode;
    return button;
  });
  var document = {
    createElement: function () { return element(); },
    getElementById: function (id) { return elements[id]; },
    querySelectorAll: function (selector) {
      if (selector === "[data-quality]") return qualities;
      if (selector === "[data-mode]") return modes;
      if (selector === "[data-shortcut]") {
        return elements["shortcut-fields"].children.map(function (label) { return label.children[1]; });
      }
      return [];
    }
  };
  var listeners = {};
  var messages = [];
  var window = { iina: {
    onMessage: function (name, callback) { listeners[name] = callback; },
    postMessage: function (name, message) { messages.push({ name: name, message: message }); }
  } };
  vm.runInNewContext(fs.readFileSync(path.join(ROOT, "ui/sidebar.js"), "utf8"), {
    window: window,
    document: document,
    Array: Array,
    JSON: JSON,
    Object: Object,
    String: String
  });
  return { elements: elements, listeners: listeners, messages: messages };
}

function shortcuts(first) {
  return {
    off: "Ctrl+0", A: first || "Ctrl+1", B: "Ctrl+2", C: "Ctrl+3",
    "A+A": "Ctrl+4", "B+B": "Ctrl+5", "C+A": "Ctrl+6", fast: "Ctrl+7", hq: "Ctrl+8"
  };
}

test("sidebar requests state and preserves shortcut edits across telemetry refreshes", function () {
  var ui = fixture();
  assert.equal(ui.messages.length, 1);
  assert.equal(ui.messages[0].name, "anime4k.action");
  assert.equal(ui.messages[0].message.action, "state");
  var render = ui.listeners["anime4k.state"];
  var base = {
    status: "Anime4K: Fast · Mode A", autoApply: true, quality: "fast", mode: "A",
    shortcuts: shortcuts(), shortcutIssues: [], telemetry: { status: "sampling" }
  };
  render(base);
  var firstInput = ui.elements["shortcut-fields"].children[1].children[1];
  firstInput.value = "Ctrl+9";
  render({
    status: base.status, autoApply: base.autoApply, quality: base.quality, mode: base.mode,
    shortcuts: shortcuts(), shortcutIssues: [], telemetry: { status: "sampling", lastRatio: 0.02 }
  });
  assert.equal(ui.elements["shortcut-fields"].children[1].children[1], firstInput);
  assert.equal(firstInput.value, "Ctrl+9");

  render({
    status: base.status, autoApply: base.autoApply, quality: base.quality, mode: base.mode,
    shortcuts: shortcuts("Ctrl+9"), shortcutIssues: [], telemetry: base.telemetry
  });
  assert.notEqual(ui.elements["shortcut-fields"].children[1].children[1], firstInput);
  assert.equal(ui.elements["shortcut-fields"].children[1].children[1].value, "Ctrl+9");
});

test("packaged sidebar declares every control and remains offline", function () {
  var info = JSON.parse(fs.readFileSync(path.join(ROOT, "Info.json"), "utf8"));
  var html = fs.readFileSync(path.join(ROOT, "ui/sidebar.html"), "utf8");
  var css = fs.readFileSync(path.join(ROOT, "ui/sidebar.css"), "utf8");
  var js = fs.readFileSync(path.join(ROOT, "ui/sidebar.js"), "utf8");
  assert.equal(info.sidebarTab.name, "Anime4K");
  ["fast", "hq"].forEach(function (quality) {
    assert.ok(html.indexOf('data-quality="' + quality + '"') !== -1);
  });
  ["A", "B", "C", "A+A", "B+B", "C+A"].forEach(function (mode) {
    assert.ok(html.indexOf('data-mode="' + mode + '"') !== -1);
  });
  ["auto-apply", "save-shortcuts", "show-shortcuts", "repair", "diagnostics"].forEach(function (id) {
    assert.ok(html.indexOf('id="' + id + '"') !== -1);
  });
  assert.ok(js.indexOf('send({ action: "state" });') !== -1);
  assert.doesNotMatch(html + js, /https?:\/\//i);

  // Keep the fork-only controls, but use the community plugin's proven
  // sidebar hierarchy: quiet title/subtitle, segmented quality control,
  // descriptive one-column preset cards, and a visually separate off action.
  assert.match(html, /class="sidebar-container"/);
  assert.match(html, /class="subtitle"/);
  assert.match(html, /class="button-group"/);
  assert.match(html, /class="mode-card"/);
  assert.match(html, /Optimized for 1080p anime/);
  assert.match(html, /Best for 720p anime/);
  assert.match(html, /Denoise-first for 480p \/ SD anime/);
  assert.match(css, /\.mode-card\.active/);
  assert.match(css, /@media \(prefers-color-scheme: dark\)/);
  assert.match(css, /:focus-visible/);
});

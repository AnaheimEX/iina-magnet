"use strict";

(function () {
  var actions = ["off", "A", "B", "C", "A+A", "B+B", "C+A", "fast", "hq"];
  var labels = { off: "Off", A: "Mode A", B: "Mode B", C: "Mode C",
    "A+A": "Mode A+A", "B+B": "Mode B+B", "C+A": "Mode C+A", fast: "Fast", hq: "HQ" };
  var state = null;
  var shortcutSignature = null;

  function send(message) { window.iina.postMessage("anime4k.action", message); }
  function all(selector) { return Array.prototype.slice.call(document.querySelectorAll(selector)); }

  function buildShortcutFields(shortcuts) {
    var root = document.getElementById("shortcut-fields");
    root.textContent = "";
    actions.forEach(function (action) {
      var label = document.createElement("label");
      var span = document.createElement("span");
      var input = document.createElement("input");
      span.textContent = labels[action];
      input.type = "text";
      input.dataset.shortcut = action;
      input.value = shortcuts[action] || "";
      input.placeholder = "Unassigned";
      label.appendChild(span);
      label.appendChild(input);
      root.appendChild(label);
    });
  }

  function shortcutsSignature(shortcuts) {
    return actions.map(function (action) { return action + "\u0000" + (shortcuts[action] || ""); }).join("\u0001");
  }

  function render(next) {
    state = next;
    document.getElementById("status").textContent = next.status;
    document.getElementById("auto-apply").checked = !!next.autoApply;
    all("[data-quality]").forEach(function (button) {
      button.classList.toggle("active", button.dataset.quality === next.quality);
    });
    all("[data-mode]").forEach(function (button) {
      button.classList.toggle("active", button.dataset.mode === next.mode);
    });
    var nextShortcuts = next.shortcuts || {};
    var nextShortcutSignature = shortcutsSignature(nextShortcuts);
    if (nextShortcutSignature !== shortcutSignature) {
      buildShortcutFields(nextShortcuts);
      shortcutSignature = nextShortcutSignature;
    }
    var issues = document.getElementById("shortcut-issues");
    var issueList = next.shortcutIssues || [];
    issues.hidden = issueList.length === 0;
    issues.textContent = issueList.map(function (issue) {
      return labels[issue.action] + ": " + issue.reason;
    }).join("\n");
  }

  all("[data-quality]").forEach(function (button) {
    button.addEventListener("click", function () { send({ action: "quality", quality: button.dataset.quality }); });
  });
  all("[data-mode]").forEach(function (button) {
    button.addEventListener("click", function () { send({ action: "mode", mode: button.dataset.mode }); });
  });
  document.getElementById("off").addEventListener("click", function () { send({ action: "off" }); });
  document.getElementById("auto-apply").addEventListener("change", function (event) {
    send({ action: "auto-apply", enabled: event.target.checked });
  });
  document.getElementById("save-shortcuts").addEventListener("click", function () {
    var values = {};
    all("[data-shortcut]").forEach(function (input) { values[input.dataset.shortcut] = input.value; });
    send({ action: "set-shortcuts", shortcuts: values });
  });
  document.getElementById("show-shortcuts").addEventListener("click", function () { send({ action: "show-shortcuts" }); });
  document.getElementById("repair").addEventListener("click", function () { send({ action: "repair" }); });
  document.getElementById("diagnostics").addEventListener("click", function () { send({ action: "diagnostics" }); });

  window.iina.onMessage("anime4k.state", render);
  window.iina.onMessage("anime4k.hint", function (hint) {
    var element = document.getElementById("hint");
    element.hidden = false;
    element.textContent = hint.lines.join("\n");
  });
  window.iina.onMessage("anime4k.diagnostics", function (details) {
    var element = document.getElementById("diagnostic-output");
    element.hidden = false;
    element.textContent = JSON.stringify(details, null, 2);
  });
  send({ action: "state" });
}());

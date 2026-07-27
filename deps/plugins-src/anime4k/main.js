"use strict";

var shaderBundle = require("./lib/shader-bundle.js");
var runtimeModule = require("./lib/runtime.js");

var runtime = runtimeModule.createRuntime({
  adapters: {
    mpv: iina.mpv,
    file: iina.file,
    preferences: iina.preferences,
    event: iina.event,
    menu: iina.menu,
    input: iina.input,
    sidebar: iina.sidebar,
    core: iina.core,
    console: iina.console
  },
  modules: {
    state: require("./lib/state.js"),
    integrity: require("./lib/integrity.js"),
    reconcile: require("./lib/reconcile.js"),
    sha256: require("./lib/sha256.js"),
    shortcuts: require("./lib/shortcuts.js"),
    telemetry: require("./lib/telemetry.js")
  },
  bundle: shaderBundle
});

runtime.start();

function iinaPluginWillUnload() {
  return runtime.unload();
}

if (typeof module !== "undefined") module.exports = runtime;

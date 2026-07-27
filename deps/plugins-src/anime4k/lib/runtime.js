"use strict";

var DEFAULT_FAILURE_OSD_INTERVAL_MS = 30000;
var DEFAULT_HEAVY_WARNING_INTERVAL_MS = 60000;
var DEFAULT_TELEMETRY_WARMUP_MS = 10000;
var DEFAULT_TELEMETRY_SAMPLE_MS = 2000;
var MODE_LABELS = { A: "A", B: "B", C: "C", "A+A": "A+A", "B+B": "B+B", "C+A": "C+A" };

function messageOf(error) {
  return error && error.message ? error.message : String(error);
}

function staleError() {
  var error = new Error("Anime4K operation was superseded");
  error.anime4kStale = true;
  return error;
}

function isOwned(ownership, path) {
  if (typeof ownership === "function") return ownership(path);
  if (ownership && typeof ownership.owns === "function") return ownership.owns(path);
  if (ownership && typeof ownership.isOwned === "function") return ownership.isOwned(path);
  if (ownership && typeof ownership.has === "function") return ownership.has(path);
  throw new Error("Anime4K ownership classifier is unavailable");
}

function requireReconcileSuccess(result) {
  if (result && result.ok === true) return result;
  var reason = result && result.reason ? result.reason : "unknown reconciliation failure";
  var detail = result && result.error ? ": " + result.error : "";
  var error = new Error("glsl-shaders reconciliation " + reason + detail);
  error.reconcileResult = result || null;
  throw error;
}

function createRuntime(options) {
  options = options || {};
  var adapters = options.adapters || {};
  var modules = options.modules || {};
  var stateModule = modules.state;
  var integrityModule = modules.integrity;
  var reconcileModule = modules.reconcile;
  var sha256Module = modules.sha256;
  var shortcutsModule = modules.shortcuts;
  var telemetryModule = modules.telemetry;
  var bundle = options.bundle;
  var failureInterval = typeof options.failureOSDIntervalMs === "number" ?
    options.failureOSDIntervalMs : DEFAULT_FAILURE_OSD_INTERVAL_MS;
  var now = typeof options.now === "function" ? options.now : function () { return Date.now(); };
  var heavyWarningInterval = typeof options.heavyWarningIntervalMs === "number" ?
    options.heavyWarningIntervalMs : DEFAULT_HEAVY_WARNING_INTERVAL_MS;
  var telemetryWarmup = typeof options.telemetryWarmupMs === "number" ?
    options.telemetryWarmupMs : DEFAULT_TELEMETRY_WARMUP_MS;
  var telemetrySample = typeof options.telemetrySampleMs === "number" ?
    options.telemetrySampleMs : DEFAULT_TELEMETRY_SAMPLE_MS;
  var repeatSchedule = typeof options.setInterval === "function" ? options.setInterval :
    (typeof setInterval === "function" ? setInterval : null);
  var cancelRepeat = typeof options.clearInterval === "function" ? options.clearInterval :
    (typeof clearInterval === "function" ? clearInterval : function () {});
  var telemetryEnabled = options.enableTelemetry !== false && telemetryModule && repeatSchedule;

  if (!stateModule || !integrityModule || !reconcileModule || !sha256Module || !bundle) {
    throw new Error("Anime4K runtime dependencies are unavailable");
  }
  if (!adapters.mpv || typeof adapters.mpv.getNative !== "function" || typeof adapters.mpv.set !== "function") {
    throw new Error("Anime4K mpv adapter is unavailable");
  }
  if (!adapters.preferences || !adapters.event || typeof adapters.event.on !== "function") {
    throw new Error("Anime4K state/event adapters are unavailable");
  }

  var currentState = stateModule.readPreferences(adapters.preferences);
  var manager = null;
  var ownership = null;
  var materializedVersionBound = false;
  var listenerId = null;
  var windowListenerId = null;
  var generation = 0;
  var started = false;
  var unloaded = false;
  var lastFailureOSDAt = -Infinity;
  var diagnostic = null;
  var shortcutValidation = null;
  var sidebarReady = false;
  var lastHeavyWarningAt = {};
  var telemetryTimer = null;
  var telemetryWarmupUntil = null;
  var telemetryMonitor = telemetryModule ? telemetryModule.createMonitor({
    sampleSeconds: telemetrySample / 1000,
    threshold: 0.01,
    requiredWindows: 3,
    warningIntervalMs: 60000
  }) : null;
  var telemetryState = null;
  var telemetryUnavailableFiles = {};
  var lastFileKey = null;

  function logFailure(message) {
    var logger = adapters.console;
    if (logger && typeof logger.error === "function") logger.error(message);
  }

  function showFailureOSD() {
    var timestamp = now();
    if (timestamp - lastFailureOSDAt < failureInterval) return;
    lastFailureOSDAt = timestamp;
    if (!emitOSD("Anime4K could not be applied; shaders were safely disabled.")) {
      logFailure("Anime4K failure OSD was unavailable; fallback to silent continue");
    }
  }

  function showOSD(message) {
    if (typeof adapters.osd === "function") {
      adapters.osd(message);
      return;
    }
    if (adapters.core && typeof adapters.core.osd === "function") {
      adapters.core.osd(message);
      return;
    }
    logFailure("Anime4K OSD adapter is unavailable");
  }

  function emitOSD(message) {
    try {
      showOSD(message);
      return true;
    } catch (error) {
      logFailure("Anime4K OSD display failed: " + messageOf(error));
      return false;
    }
  }

  function stateLabel() {
    if (currentState.mode === "off") return "Anime4K: Off";
    return "Anime4K: " + (currentState.quality === "hq" ? "HQ" : "Fast") +
      " · Mode " + MODE_LABELS[currentState.mode];
  }

  function shortcutIssueText() {
    if (!shortcutValidation || !shortcutValidation.issues.length) return null;
    return shortcutValidation.issues.map(function (issue) {
      return issue.action + ": " + (issue.binding || "Unassigned") + " (" + issue.reason + ")";
    }).join("\n");
  }

  function uiSnapshot() {
    return {
      mode: currentState.mode,
      quality: currentState.quality,
      autoApply: currentState.autoApply,
      status: stateLabel(),
      shortcuts: shortcutValidation ? shortcutValidation.stored : currentState.shortcuts,
      shortcutIssues: shortcutValidation ? shortcutValidation.issues : [],
      diagnostic: diagnostic,
      telemetry: telemetryState
    };
  }

  function postSidebar(name, data) {
    if (!sidebarReady || !adapters.sidebar || typeof adapters.sidebar.postMessage !== "function") return;
    try { adapters.sidebar.postMessage(name, data); } catch (error) { logFailure("Anime4K sidebar update failed: " + messageOf(error)); }
  }

  function refreshSidebar() {
    postSidebar("anime4k.state", uiSnapshot());
  }

  function validateShortcuts() {
    if (!shortcutsModule) return null;
    shortcutValidation = shortcutsModule.validate(currentState.shortcuts, adapters.input || {});
    return shortcutValidation;
  }

  function menuOptions(selected, binding, enabled) {
    var result = { selected: !!selected, enabled: enabled !== false };
    if (binding) result.keyBinding = binding;
    return result;
  }

  function menuItem(title, action, selected, binding, enabled) {
    return adapters.menu.item(title, action, menuOptions(selected, binding, enabled));
  }

  function buildMenu() {
    if (!adapters.menu || typeof adapters.menu.item !== "function" ||
        typeof adapters.menu.addItem !== "function") return;
    var validation = validateShortcuts() || { bindings: {}, issues: [] };
    adapters.menu.removeAllItems();
    adapters.menu.addItem(menuItem(stateLabel(), null, false, null, false));
    adapters.menu.addItem(adapters.menu.separator());
    adapters.menu.addItem(menuItem("Off", function () { disable(); }, currentState.mode === "off", validation.bindings.off));

    var quality = menuItem("Quality", null, false);
    quality.addSubMenuItem(menuItem("Fast", function () { selectQuality("fast"); },
      currentState.quality === "fast", validation.bindings.fast));
    quality.addSubMenuItem(menuItem("HQ", function () { selectQuality("hq"); },
      currentState.quality === "hq", validation.bindings.hq));
    adapters.menu.addItem(quality);

    var modes = menuItem("Mode", null, false);
    stateModule.NON_OFF_MODES.forEach(function (mode) {
      modes.addSubMenuItem(menuItem("Mode " + MODE_LABELS[mode], function () {
        select(currentState.quality, mode);
      }, currentState.mode === mode, validation.bindings[mode]));
    });
    adapters.menu.addItem(modes);
    adapters.menu.addItem(menuItem("Auto Apply", function () { setAutoApply(!currentState.autoApply); },
      currentState.autoApply));
    adapters.menu.addItem(adapters.menu.separator());
    adapters.menu.addItem(menuItem("Show Shortcuts", function () { showShortcutHint(true); }, false));
    adapters.menu.addItem(menuItem("Repair Shader Bundle", function () { repair(); }, false));
    adapters.menu.addItem(menuItem("Diagnostics", function () { showDiagnostics(); }, false));
    if (validation.issues.length) {
      var issueRoot = menuItem("Shortcut Conflicts (" + validation.issues.length + ")", null, false, null, false);
      validation.issues.forEach(function (issue) {
        issueRoot.addSubMenuItem(menuItem(issue.action + ": " + issue.reason, null, false, null, false));
      });
      adapters.menu.addItem(issueRoot);
    }
    if (typeof adapters.menu.forceUpdate === "function") adapters.menu.forceUpdate();
  }

  function refreshUI(rebuildMenu) {
    try {
      if (rebuildMenu) buildMenu();
      else validateShortcuts();
      refreshSidebar();
    } catch (error) {
      logFailure("Anime4K UI refresh failed: " + messageOf(error));
    }
  }

  function showShortcutHint(manual) {
    var validation = validateShortcuts() || { bindings: {}, issues: [] };
    var lines = shortcutsModule ? shortcutsModule.hintLines(validation) : [];
    emitOSD("Anime4K shortcuts: " + lines.join(" · "));
    postSidebar("anime4k.hint", { lines: lines, issues: validation.issues });
    if (!currentState.shortcutHintAcknowledged) persist(stateModule.acknowledgeShortcuts(currentState));
    if (manual && sidebarReady && adapters.sidebar && typeof adapters.sidebar.show === "function") {
      try { adapters.sidebar.show(); } catch (error) { logFailure("Anime4K sidebar show failed: " + messageOf(error)); }
    }
    refreshUI(true);
  }

  function warnShortcutIssues() {
    var issues = shortcutIssueText();
    if (issues) emitOSD("Anime4K shortcut conflict: " + issues.replace(/\n/g, " · "));
  }

  function warnHeavySelection() {
    if (currentState.mode === "off") return;
    if (currentState.quality !== "hq" && ["A+A", "B+B", "C+A"].indexOf(currentState.mode) === -1) return;
    var key = currentState.quality + "/" + currentState.mode;
    var timestamp = now();
    if (Object.prototype.hasOwnProperty.call(lastHeavyWarningAt, key) &&
        timestamp - lastHeavyWarningAt[key] < heavyWarningInterval) return;
    lastHeavyWarningAt[key] = timestamp;
    emitOSD("Anime4K " + key + " may be GPU intensive; switch to Fast or Off if playback drops frames.");
  }

  function recordFailure(operation, error, cleanupError) {
    diagnostic = {
      operation: operation,
      error: messageOf(error),
      cleanupError: cleanupError ? messageOf(cleanupError) : null,
      generation: generation,
      timestamp: now()
    };
    logFailure("Anime4K " + operation + " failed: " + diagnostic.error +
      (diagnostic.cleanupError ? "; cleanup failed: " + diagnostic.cleanupError : ""));
    if (["select", "quality", "enable", "disable", "repair"].indexOf(operation) !== -1) {
      emitOSD("Anime4K could not be applied; shaders were safely disabled.");
    } else {
      showFailureOSD();
    }
    refreshSidebar();
  }

  function stopTelemetry() {
    if (telemetryTimer !== null) {
      cancelRepeat(telemetryTimer);
      telemetryTimer = null;
    }
    telemetryWarmupUntil = null;
  }

  function sampleTelemetry() {
    if (!telemetryEnabled || unloaded || currentState.mode === "off" || !lastFileKey) return;
    if (telemetryWarmupUntil !== null && now() < telemetryWarmupUntil) return;
    var snapshot = telemetryModule.readSnapshot(function (name) { return adapters.mpv.getNative(name); });
    var result = telemetryMonitor.sample(snapshot, now());
    telemetryState = telemetryMonitor.getState();
    if (result.status === "disabled") {
      telemetryUnavailableFiles[lastFileKey] = true;
      stopTelemetry();
      refreshSidebar();
      return;
    }
    if (result.warning) {
      emitOSD("Anime4K sustained frame pressure detected; consider Fast or Off. The selected mode was not changed.");
    }
    refreshSidebar();
  }

  function startTelemetry() {
    stopTelemetry();
    if (!telemetryEnabled || !lastFileKey || currentState.mode === "off" || telemetryUnavailableFiles[lastFileKey]) return;
    telemetryMonitor.begin(lastFileKey, currentState.quality + "/" + currentState.mode);
    telemetryState = telemetryMonitor.getState();
    telemetryWarmupUntil = now() + telemetryWarmup;
    telemetryTimer = repeatSchedule(sampleTelemetry, telemetrySample);
    refreshSidebar();
  }

  function uniquePaths(paths) {
    var seen = Object.create(null);
    return paths.filter(function (path) {
      if (typeof path !== "string" || seen[path]) return false;
      seen[path] = true;
      return true;
    });
  }

  function priorDataPaths() {
    var paths = Array.isArray(options.priorDataPaths) ? options.priorDataPaths.slice() : [];
    var manifest = bundle && bundle.manifest;
    if (integrityModule && typeof integrityModule.derivePriorDataPaths === "function" && manifest) {
      paths = paths.concat(integrityModule.derivePriorDataPaths(
        adapters.file, currentState.shaderBundleVersion, manifest
      ));
    }
    return uniquePaths(paths);
  }

  function bindMaterializedVersion(activeManager) {
    var version = activeManager.manifest.shaderBundleVersion;
    if (!materializedVersionBound || currentState.shaderBundleVersion !== version) {
      persist(stateModule.setShaderBundleVersion(currentState, version));
      materializedVersionBound = true;
    }
    return version;
  }

  function ensureManager() {
    if (manager) return manager;
    manager = integrityModule.createManager({
      bundle: bundle,
      file: adapters.file,
      sha256: sha256Module,
      priorDataPaths: priorDataPaths()
    });
    ownership = reconcileModule.createOwnership(manager.ownedLocalPaths);
    return manager;
  }

  function ensureOwnership() {
    if (ownership) return ownership;
    try {
      ensureManager();
      return ownership;
    } catch (managerError) {
      var manifest = bundle && bundle.manifest;
      if (!manifest || !Array.isArray(manifest.shaders) ||
          typeof manifest.shaderBundleVersion !== "number" ||
          !adapters.file || typeof adapters.file.resolveLocal !== "function") {
        throw managerError;
      }
      var fallbackVirtualPaths = manifest.shaders.map(function (record) {
        return integrityModule.dataPath(manifest.shaderBundleVersion, record.file);
      }).concat(priorDataPaths());
      if (fallbackVirtualPaths.some(function (path) {
        return typeof path !== "string" || !/^@data\/anime4k-v[1-9][0-9]*--[^/\\]+$/.test(path);
      })) throw managerError;
      var fallbackPaths = uniquePaths(fallbackVirtualPaths).map(function (path) {
        return adapters.file.resolveLocal(path);
      });
      if (fallbackPaths.some(function (path) { return typeof path !== "string" || !path; })) throw managerError;
      ownership = reconcileModule.createOwnership(fallbackPaths);
      return ownership;
    }
  }

  function assertCurrent(token, allowUnloaded) {
    if (token !== generation || (unloaded && !allowUnloaded)) throw staleError();
  }

  function readNative(token, allowUnloaded) {
    assertCurrent(token, allowUnloaded);
    var value = adapters.mpv.getNative("glsl-shaders");
    assertCurrent(token, allowUnloaded);
    return value;
  }

  function writeNative(token, value, allowUnloaded) {
    assertCurrent(token, allowUnloaded);
    adapters.mpv.set("glsl-shaders", value);
    assertCurrent(token, allowUnloaded);
  }

  function reconcilerFor(token, allowUnloaded) {
    ensureOwnership();
    return new reconcileModule.Reconciler({
      read: function () { return readNative(token, allowUnloaded); },
      write: function (value) { writeNative(token, value, allowUnloaded); },
      ownership: ownership
    });
  }

  function nativeHasOwned(token, allowUnloaded) {
    ensureOwnership();
    var value = readNative(token, allowUnloaded);
    if (!Array.isArray(value) || value.some(function (entry) { return typeof entry !== "string"; })) {
      throw new Error("glsl-shaders must be a native Array<string>");
    }
    return value.some(function (entry) { return isOwned(ownership, entry); });
  }

  function cleanup(token, onlyWhenPresent, allowUnloaded) {
    if (onlyWhenPresent && !nativeHasOwned(token, allowUnloaded)) return false;
    requireReconcileSuccess(reconcilerFor(token, allowUnloaded).cleanup());
    assertCurrent(token, allowUnloaded);
    return true;
  }

  function failCurrent(operation, error, token) {
    if (token !== generation || unloaded || (error && error.anime4kStale)) return false;
    var cleanupError = null;
    try {
      cleanup(token, true);
    } catch (caught) {
      cleanupError = caught;
    }
    recordFailure(operation, error, cleanupError);
    return false;
  }

  function persist(next) {
    currentState = stateModule.writePreferences(adapters.preferences, next);
    return currentState;
  }

  function applyState(next, operation) {
    var token = ++generation;
    try {
      var activeManager = ensureManager();
      activeManager.ensureMaterialized();
      var materializedVersion = bindMaterializedVersion(activeManager);
      next = stateModule.setShaderBundleVersion(next, materializedVersion);
      assertCurrent(token);
      var catalog = bundle.manifest.presets[next.quality];
      if (!catalog || !Array.isArray(catalog[next.mode])) throw new Error("unknown Anime4K preset");
      var desired = activeManager.pathsForIds(catalog[next.mode]);
      requireReconcileSuccess(reconcilerFor(token).apply(desired));
      assertCurrent(token);
      persist(next);
      diagnostic = null;
      return true;
    } catch (error) {
      return failCurrent(operation, error, token);
    }
  }

  function enable() {
    if (unloaded) return false;
    return activate(stateModule.enable(currentState), "enable");
  }

  function select(quality, mode) {
    if (unloaded) return false;
    var next = stateModule.select(currentState, quality, mode);
    if (mode === "off") return disable();
    return activate(next, "select");
  }

  function activate(next, operation) {
    var shouldHint = shortcutsModule && !currentState.shortcutHintAcknowledged;
    if (shouldHint) next = stateModule.acknowledgeShortcuts(next);
    var success = applyState(next, operation);
    if (!success) return false;
    var lines;
    if (shouldHint) {
      var validation = validateShortcuts() || { bindings: {}, issues: [] };
      lines = shortcutsModule.hintLines(validation);
      postSidebar("anime4k.hint", { lines: lines, issues: validation.issues });
    }
    refreshUI(true);
    var status = stateLabel();
    emitOSD(status);
    if (shouldHint) {
      emitOSD("Anime4K shortcuts: " + lines.join(" · "));
    }
    warnHeavySelection();
    startTelemetry();
    return true;
  }

  function selectQuality(quality) {
    if (unloaded) return false;
    var next = stateModule.setQuality(currentState, quality);
    if (next.mode !== "off") return activate(next, "quality");
    persist(next);
    refreshUI(true);
    emitOSD(stateLabel());
    return true;
  }

  function setAutoApply(enabled) {
    if (unloaded) return false;
    persist(stateModule.setAutoApply(currentState, enabled));
    refreshUI(true);
    emitOSD(stateLabel() + " · Auto Apply " + (enabled ? "On" : "Off"));
    return true;
  }

  function updateShortcuts(nextShortcuts) {
    if (unloaded || !shortcutsModule) return false;
    var combined = {};
    shortcutsModule.ACTIONS.forEach(function (action) {
      combined[action] = currentState.shortcuts[action];
      if (nextShortcuts && Object.prototype.hasOwnProperty.call(nextShortcuts, action)) {
        combined[action] = nextShortcuts[action];
      }
    });
    var validation = shortcutsModule.validate(combined, adapters.input || {});
    persist(stateModule.setShortcuts(currentState, validation.stored));
    shortcutValidation = validation;
    buildMenu();
    refreshSidebar();
    warnShortcutIssues();
    return validation.issues.length === 0;
  }

  function repair() {
    if (unloaded) return false;
    try {
      var activeManager = ensureManager();
      activeManager.ensureMaterialized();
      bindMaterializedVersion(activeManager);
      if (currentState.mode !== "off") return activate(currentState, "repair");
      diagnostic = null;
      refreshUI(true);
      emitOSD("Anime4K shader bundle verified and repaired.");
      return true;
    } catch (error) {
      return failCurrent("repair", error, generation);
    }
  }

  function showDiagnostics() {
    var detail = diagnostic ? diagnostic.error : "healthy";
    var telemetryDetail = telemetryState ? telemetryState.status : "idle";
    refreshSidebar();
    emitOSD(stateLabel() + " · Integrity " + detail + " · Telemetry " + telemetryDetail);
    postSidebar("anime4k.diagnostics", { diagnostic: diagnostic, telemetry: telemetryState });
    return true;
  }

  function disable() {
    if (unloaded) return false;
    var token = ++generation;
    var next = stateModule.disable(currentState);
    persist(next);
    try {
      cleanup(token, true);
      diagnostic = null;
      stopTelemetry();
      telemetryState = null;
      refreshUI(true);
      emitOSD(stateLabel());
      return true;
    } catch (error) {
      stopTelemetry();
      refreshUI(true);
      return failCurrent("disable", error, token);
    }
  }

  function onFileLoaded(file) {
    if (unloaded) return false;
    lastFileKey = typeof file === "string" && file ? file : "unknown";
    stopTelemetry();
    if (currentState.mode !== "off" && currentState.autoApply) {
      var applied = applyState(currentState, "file-loaded");
      if (applied) startTelemetry();
      refreshUI(false);
      return applied;
    }
    var token = ++generation;
    try {
      cleanup(token, true);
      telemetryState = null;
      refreshUI(false);
      return true;
    } catch (error) {
      return failCurrent("file-loaded cleanup", error, token);
    }
  }

  function handleSidebarAction(message) {
    if (!message || typeof message !== "object") return false;
    switch (message.action) {
    case "state": refreshSidebar(); return true;
    case "off": return disable();
    case "mode": return select(currentState.quality, message.mode);
    case "quality": return selectQuality(message.quality);
    case "auto-apply": return setAutoApply(!!message.enabled);
    case "set-shortcuts": return updateShortcuts(message.shortcuts || {});
    case "show-shortcuts": return showShortcutHint(true);
    case "repair": return repair();
    case "diagnostics": return showDiagnostics();
    default: return false;
    }
  }

  function setupSidebar() {
    if (sidebarReady || !adapters.sidebar || typeof adapters.sidebar.loadFile !== "function") return false;
    adapters.sidebar.loadFile("ui/sidebar.html");
    // loadFile clears the host message hub, so handlers must be registered after it.
    if (typeof adapters.sidebar.onMessage === "function") {
      adapters.sidebar.onMessage("anime4k.action", handleSidebarAction);
    }
    sidebarReady = true;
    refreshSidebar();
    return true;
  }

  function start() {
    if (started || unloaded) return false;
    started = true;
    try {
      var activeManager = ensureManager();
      activeManager.ensureMaterialized();
      bindMaterializedVersion(activeManager);
    } catch (error) {
      failCurrent("startup integrity", error, ++generation);
    }
    listenerId = adapters.event.on("iina.file-loaded", onFileLoaded);
    if (adapters.sidebar) {
      if (adapters.core && adapters.core.window && adapters.core.window.loaded === true) {
        try { setupSidebar(); } catch (error) { logFailure("Anime4K sidebar deferred: " + messageOf(error)); }
      }
      windowListenerId = adapters.event.on("iina.window-loaded", function () {
        try { setupSidebar(); } catch (error) { logFailure("Anime4K sidebar load failed: " + messageOf(error)); }
      });
    }
    refreshUI(true);
    warnShortcutIssues();
    return true;
  }

  function unload() {
    if (unloaded) return false;
    unloaded = true;
    var token = ++generation;
    stopTelemetry();
    if (listenerId !== null && listenerId !== undefined && typeof adapters.event.off === "function") {
      adapters.event.off("iina.file-loaded", listenerId);
      listenerId = null;
    }
    if (windowListenerId !== null && windowListenerId !== undefined && typeof adapters.event.off === "function") {
      adapters.event.off("iina.window-loaded", windowListenerId);
      windowListenerId = null;
    }
    if (adapters.menu && typeof adapters.menu.removeAllItems === "function") {
      adapters.menu.removeAllItems();
      if (typeof adapters.menu.forceUpdate === "function") adapters.menu.forceUpdate();
    }
    try {
      cleanup(token, true, true);
      diagnostic = null;
    } catch (error) {
      recordFailure("unload", error, null);
    }
    return true;
  }

  return {
    start: start,
    enable: enable,
    select: select,
    selectQuality: selectQuality,
    disable: disable,
    setAutoApply: setAutoApply,
    updateShortcuts: updateShortcuts,
    showShortcuts: function () { return showShortcutHint(true); },
    repair: repair,
    showDiagnostics: showDiagnostics,
    fileLoaded: onFileLoaded,
    unload: unload,
    getState: function () { return stateModule.migrate(currentState); },
    getDiagnostic: function () { return diagnostic; },
    getShortcutValidation: function () { return shortcutValidation; },
    getTelemetry: function () { return telemetryState; },
    getGeneration: function () { return generation; },
    isUnloaded: function () { return unloaded; }
  };
}

module.exports = {
  DEFAULT_FAILURE_OSD_INTERVAL_MS: DEFAULT_FAILURE_OSD_INTERVAL_MS,
  DEFAULT_HEAVY_WARNING_INTERVAL_MS: DEFAULT_HEAVY_WARNING_INTERVAL_MS,
  DEFAULT_TELEMETRY_WARMUP_MS: DEFAULT_TELEMETRY_WARMUP_MS,
  DEFAULT_TELEMETRY_SAMPLE_MS: DEFAULT_TELEMETRY_SAMPLE_MS,
  createRuntime: createRuntime
};

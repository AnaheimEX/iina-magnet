"use strict";

var COUNTERS = ["frame-drop-count", "mistimed-frame-count", "vo-delayed-frame-count"];

function finiteNumber(value) {
  return typeof value === "number" && isFinite(value);
}

function frameBudgetMs(fps) {
  return finiteNumber(fps) && fps > 0 ? 1000 / fps : null;
}

function readSnapshot(getNative) {
  var snapshot = {};
  for (var index = 0; index < COUNTERS.length; index += 1) {
    var name = COUNTERS[index];
    var value;
    try {
      value = getNative(name);
    } catch (error) {
      return null;
    }
    if (!finiteNumber(value)) return null;
    snapshot[name] = value;
  }
  try {
    snapshot["estimated-vf-fps"] = getNative("estimated-vf-fps");
  } catch (error) {
    return null;
  }
  if (!finiteNumber(snapshot["estimated-vf-fps"]) || snapshot["estimated-vf-fps"] <= 0) return null;
  return snapshot;
}

function createMonitor(options) {
  options = options || {};
  var sampleSeconds = typeof options.sampleSeconds === "number" ? options.sampleSeconds : 2;
  var threshold = typeof options.threshold === "number" ? options.threshold : 0.01;
  var requiredWindows = typeof options.requiredWindows === "number" ? options.requiredWindows : 3;
  var warningIntervalMs = typeof options.warningIntervalMs === "number" ? options.warningIntervalMs : 60000;
  var warnings = {};
  var state = null;

  function begin(fileKey, modeKey) {
    state = {
      fileKey: String(fileKey || "unknown"),
      modeKey: String(modeKey || "off"),
      baseline: null,
      consecutive: 0,
      lastRatio: null,
      fps: null,
      adverse: null,
      denominator: null,
      ratio: null,
      frameBudgetMs: null,
      status: "warming"
    };
    return getState();
  }

  function disable(reason) {
    if (state) {
      state.status = "disabled";
      state.reason = reason || "unavailable";
    }
    return getState();
  }

  function sample(snapshot, timestamp) {
    if (!state) return { status: "idle", warning: false };
    if (!snapshot) return { status: disable("unavailable").status, warning: false };
    if (!state.baseline) {
      state.baseline = snapshot;
      state.status = "sampling";
      state.fps = snapshot["estimated-vf-fps"];
      state.adverse = null;
      state.denominator = state.fps * sampleSeconds;
      state.ratio = null;
      state.frameBudgetMs = frameBudgetMs(state.fps);
      return { status: state.status, warning: false, baseline: true };
    }
    var adverse = 0;
    var reset = false;
    COUNTERS.forEach(function (name) {
      var delta = snapshot[name] - state.baseline[name];
      if (delta < 0) reset = true;
      else adverse += delta;
    });
    if (reset) {
      state.baseline = snapshot;
      state.consecutive = 0;
      state.lastRatio = null;
      state.fps = snapshot["estimated-vf-fps"];
      state.adverse = null;
      state.denominator = state.fps * sampleSeconds;
      state.ratio = null;
      state.frameBudgetMs = frameBudgetMs(state.fps);
      return { status: state.status, warning: false, reset: true };
    }
    state.baseline = snapshot;
    var denominator = snapshot["estimated-vf-fps"] * sampleSeconds;
    if (!finiteNumber(denominator) || denominator <= 0) {
      return { status: disable("unavailable").status, warning: false };
    }
    var ratio = adverse / denominator;
    state.fps = snapshot["estimated-vf-fps"];
    state.adverse = adverse;
    state.denominator = denominator;
    state.ratio = ratio;
    state.frameBudgetMs = frameBudgetMs(state.fps);
    state.lastRatio = ratio;
    state.consecutive = ratio > threshold ? state.consecutive + 1 : 0;
    var key = state.fileKey + "|" + state.modeKey;
    var lastWarning = own(warnings, key) ? warnings[key] : -Infinity;
    var warning = state.consecutive >= requiredWindows && timestamp - lastWarning >= warningIntervalMs;
    if (warning) warnings[key] = timestamp;
    return {
      status: state.status,
      warning: warning,
      ratio: ratio,
      consecutive: state.consecutive,
      adverse: adverse,
      denominator: denominator,
      fps: state.fps,
      frameBudgetMs: state.frameBudgetMs
    };
  }

  function own(object, key) {
    return Object.prototype.hasOwnProperty.call(object, key);
  }

  function getState() {
    if (!state) return null;
    return {
      fileKey: state.fileKey,
      modeKey: state.modeKey,
      consecutive: state.consecutive,
      lastRatio: state.lastRatio,
      fps: state.fps,
      adverse: state.adverse,
      denominator: state.denominator,
      ratio: state.ratio,
      frameBudgetMs: state.frameBudgetMs,
      status: state.status,
      reason: state.reason || null
    };
  }

  return { begin: begin, disable: disable, sample: sample, getState: getState };
}

module.exports = {
  COUNTERS: COUNTERS.slice(),
  frameBudgetMs: frameBudgetMs,
  readSnapshot: readSnapshot,
  createMonitor: createMonitor
};

"use strict";

var test = require("node:test");
var assert = require("node:assert/strict");
var telemetry = require("../lib/telemetry.js");

function snapshot(drop, mistimed, delayed, fps) {
  return {
    "frame-drop-count": drop,
    "mistimed-frame-count": mistimed,
    "vo-delayed-frame-count": delayed,
    "estimated-vf-fps": fps
  };
}

test("warning requires three consecutive 2-second windows above one percent", function () {
  var monitor = telemetry.createMonitor({ sampleSeconds: 2, threshold: 0.01, requiredWindows: 3 });
  monitor.begin("file", "fast/A");
  assert.equal(monitor.sample(snapshot(0, 0, 0, 60), 0).baseline, true);
  assert.equal(monitor.sample(snapshot(2, 0, 0, 60), 2000).warning, false);
  assert.equal(monitor.sample(snapshot(4, 0, 0, 60), 4000).warning, false);
  var third = monitor.sample(snapshot(6, 0, 0, 60), 6000);
  assert.equal(third.warning, true);
  assert.equal(third.consecutive, 3);
  assert.ok(third.ratio > 0.01);
  assert.equal(third.fps, 60);
  assert.equal(third.adverse, 2);
  assert.equal(third.denominator, 120);
  assert.equal(third.frameBudgetMs, 1000 / 60);
  assert.deepEqual(monitor.getState(), {
    fileKey: "file", modeKey: "fast/A", consecutive: 3, lastRatio: 2 / 120,
    fps: 60, adverse: 2, denominator: 120, ratio: 2 / 120,
    frameBudgetMs: 1000 / 60, status: "sampling", reason: null
  });
});

test("frame budget helper exposes 24/30/60 fps budgets without claiming pass timing", function () {
  assert.equal(telemetry.frameBudgetMs(24), 1000 / 24);
  assert.equal(telemetry.frameBudgetMs(30), 1000 / 30);
  assert.equal(telemetry.frameBudgetMs(60), 1000 / 60);
  assert.equal(telemetry.frameBudgetMs(0), null);
  assert.equal(telemetry.frameBudgetMs("60"), null);
});

test("counter decrease resets baseline and low pressure clears the streak", function () {
  var monitor = telemetry.createMonitor();
  monitor.begin("file", "hq/B+B");
  monitor.sample(snapshot(10, 10, 10, 30), 0);
  monitor.sample(snapshot(12, 10, 10, 30), 2000);
  assert.equal(monitor.sample(snapshot(1, 1, 1, 30), 4000).reset, true);
  assert.equal(monitor.getState().consecutive, 0);
  var low = monitor.sample(snapshot(1, 1, 1, 30), 6000);
  assert.equal(low.consecutive, 0);
  assert.equal(low.warning, false);
});

test("warning rate limit is isolated per file and mode for 60 seconds", function () {
  var monitor = telemetry.createMonitor({ warningIntervalMs: 60000 });
  function overload(file, mode, start) {
    monitor.begin(file, mode);
    monitor.sample(snapshot(0, 0, 0, 60), start);
    monitor.sample(snapshot(2, 0, 0, 60), start + 2000);
    monitor.sample(snapshot(4, 0, 0, 60), start + 4000);
    return monitor.sample(snapshot(6, 0, 0, 60), start + 6000).warning;
  }
  assert.equal(overload("file", "fast/A", 0), true);
  assert.equal(overload("file", "fast/A", 10000), false);
  assert.equal(overload("file", "fast/B", 10000), true);
  assert.equal(overload("other", "fast/A", 10000), true);
  assert.equal(overload("file", "fast/A", 61000), true);
});

test("missing or non-numeric counters disable telemetry only", function () {
  var values = snapshot(1, 2, 3, 24);
  assert.deepEqual(telemetry.readSnapshot(function (name) { return values[name]; }), values);
  values["mistimed-frame-count"] = "unknown";
  assert.equal(telemetry.readSnapshot(function (name) { return values[name]; }), null);
  var monitor = telemetry.createMonitor();
  monitor.begin("file", "fast/A");
  assert.equal(monitor.sample(null, 0).status, "disabled");
  assert.equal(monitor.getState().reason, "unavailable");
});

"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

const reconcile = require("../lib/reconcile.js");

const ownedA = "/Users/test/Library/Application Support/IINA/plugins/.data/io.iina.magnet.anime4k/v1 Anime4K_A.glsl";
const ownedB = "/Users/test/Library/Application Support/IINA/plugins/.data/io.iina.magnet.anime4k/v1:日本語:B.glsl";
const ownedC = "/Users/test/Library/Application Support/IINA/plugins/.data/io.iina.magnet.anime4k/v1-C.glsl";
const retained = "/Users/test/Library/Application Support/IINA/plugins/.data/io.iina.magnet.anime4k/v0-old.glsl";
const ownership = reconcile.createOwnership([ownedA, ownedB, ownedC], [retained]);

function makeHarness(initial, hooks = {}) {
  let state = initial.slice();
  let reads = 0;
  const writes = [];
  return {
    read() {
      reads += 1;
      if (hooks.read) return hooks.read({ reads, state, setState: (next) => { state = next.slice(); } });
      return state.slice();
    },
    write(next) {
      writes.push(next.slice());
      if (hooks.write) return hooks.write({ writes: writes.length, next, state, setState: (value) => { state = value.slice(); } });
      state = next.slice();
    },
    state: () => state.slice(),
    reads: () => reads,
    writes,
  };
}

function controllerFor(harness) {
  return new reconcile.Reconciler({
    read: harness.read,
    write: harness.write,
    ownership,
  });
}

test("native array contract rejects strings and non-string elements", () => {
  assert.deepEqual(reconcile.requireNativeArray(["a", "b"]), ["a", "b"]);
  assert.throws(() => reconcile.requireNativeArray("a:b"), /native array/);
  assert.throws(() => reconcile.requireNativeArray(["a", 2]), /must be a string/);
  assert.equal(reconcile.verify(["a"], "a"), false);
  assert.equal(reconcile.verify(["a"], ["a", 2]), false);
});

test("ownership is exact and refuses prefix, traversal, alternate, and similar paths", () => {
  assert.equal(ownership.owns(ownedA), true);
  assert.equal(ownership.owns(retained), true);
  for (const hostile of [
    `${ownedA}.backup`,
    ownedA.slice(0, -5),
    ownedA.replace("/v1 ", "/v1/../v1 "),
    ownedA.replace("/plugins/", "/plugins//"),
    ownedA.replace("anime4k", "anime4k-copy"),
    `file://${ownedA}`,
    ownedA.normalize("NFD"),
  ]) {
    if (hostile !== ownedA) assert.equal(ownership.owns(hostile), false, hostile);
  }

  assert.throws(() => reconcile.createOwnership(["relative.glsl"]), /absolute/);
  assert.throws(() => reconcile.createOwnership(["/root/../owned.glsl"]), /canonical/);
  assert.throws(() => reconcile.createOwnership(["/root//owned.glsl"]), /canonical/);
  assert.throws(() => reconcile.createOwnership(["/root/./owned.glsl"]), /canonical/);
});

test("stripOwned and merge preserve non-owned spaces, Unicode, colons, duplicates, and order", () => {
  const userA = "/tmp/user shader.glsl";
  const userB = "/tmp/用户:シェーダー.glsl";
  const current = [userA, ownedA, userB, userA, retained, userB, ownedB];
  assert.deepEqual(reconcile.stripOwned(current, ownership), [userA, userB, userA, userB]);
  assert.deepEqual(
    reconcile.merge(current, ownership, [ownedC, ownedA]),
    [userA, userB, userA, userB, ownedC, ownedA],
  );
  assert.throws(() => reconcile.merge(current, ownership, ["/tmp/not-owned.glsl"]), /exact ownership/);
});

test("fixed-seed 100-case corpus preserves every exact non-owned element", () => {
  let seed = 0x4a4b2026;
  function random() {
    seed = ((seed * 1664525) + 1013904223) >>> 0;
    return seed / 0x100000000;
  }

  const owned = ownership.paths;
  const desiredSets = [[], [ownedA], [ownedB, ownedC], [ownedC, ownedA]];
  for (let caseIndex = 0; caseIndex < 100; caseIndex += 1) {
    const current = [];
    const expectedNonOwned = [];
    const length = 3 + Math.floor(random() * 20);
    for (let index = 0; index < length; index += 1) {
      if (random() < 0.38) {
        current.push(owned[Math.floor(random() * owned.length)]);
      } else {
        const base = `/tmp/corpus ${Math.floor(random() * 7)}:用户/${caseIndex % 5}.glsl`;
        const value = random() < 0.25 ? `${ownedA}.similar-${index % 3}` : base;
        current.push(value);
        expectedNonOwned.push(value);
      }
    }
    const desired = desiredSets[Math.floor(random() * desiredSets.length)];
    assert.deepEqual(reconcile.stripOwned(current, ownership), expectedNonOwned, `strip case ${caseIndex}`);
    assert.deepEqual(reconcile.merge(current, ownership, desired), expectedNonOwned.concat(desired), `merge case ${caseIndex}`);
  }
});

test("apply, switch, disable, cleanup, and unload are idempotent", () => {
  const user = "/tmp/user duplicate.glsl";
  const harness = makeHarness([user, user]);
  const controller = controllerFor(harness);

  assert.equal(controller.apply([ownedA, ownedB]).ok, true);
  assert.deepEqual(harness.state(), [user, user, ownedA, ownedB]);
  assert.equal(harness.writes.length, 1);

  const repeated = controller.apply([ownedA, ownedB]);
  assert.equal(repeated.ok, true);
  assert.equal(repeated.changed, false);
  assert.equal(harness.writes.length, 1);

  assert.equal(controller.apply([ownedC]).ok, true);
  assert.deepEqual(harness.state(), [user, user, ownedC]);
  assert.equal(harness.writes.length, 2);

  assert.equal(controller.disable().ok, true);
  assert.deepEqual(harness.state(), [user, user]);
  assert.equal(harness.writes.length, 3);

  assert.equal(controller.cleanup().changed, false);
  assert.equal(controller.unload().changed, false);
  assert.equal(harness.writes.length, 3, "no owned entries means no cleanup write");
});

test("non-array mpv values fail without a string parser or write", () => {
  let reads = 0;
  const writes = [];
  const controller = new reconcile.Reconciler({
    ownership,
    read() { reads += 1; return `${ownedA}:${ownedB}`; },
    write(value) { writes.push(value); },
  });
  const result = controller.apply([ownedA]);
  assert.equal(result.ok, false);
  assert.equal(result.reason, "initial-read-failed");
  assert.equal(result.cleanup.reason, "cleanup-read-failed");
  assert.equal(reads, 2, "failure cleanup performs one fresh latest read");
  assert.equal(writes.length, 0);
});

test("readback interleaving re-reads latest and removes only exact owned paths", () => {
  const user = "/tmp/original.glsl";
  const concurrent = "/tmp/concurrent 用户:shader.glsl";
  const harness = makeHarness([user], {
    read({ reads, state, setState }) {
      if (reads === 2) {
        const interleaved = state.concat([concurrent]);
        setState(interleaved);
        return interleaved.slice();
      }
      return state.slice();
    },
    write({ next, setState }) { setState(next); },
  });
  const result = controllerFor(harness).apply([ownedA, ownedB]);
  assert.equal(result.ok, false);
  assert.equal(result.reason, "readback-mismatch");
  assert.equal(result.cleanup.ok, true);
  assert.deepEqual(harness.state(), [user, concurrent]);
  assert.equal(harness.reads(), 4, "initial, mismatched readback, latest cleanup read, cleanup readback");
  assert.equal(harness.writes.length, 2, "one primary write and one cleanup write");
});

test("write exception cleans from a fresh latest state", () => {
  const user = "/tmp/original.glsl";
  const concurrent = "/tmp/added-during-failed-write.glsl";
  const harness = makeHarness([user], {
    write({ writes, next, setState }) {
      if (writes === 1) {
        setState(next.concat([concurrent]));
        throw new Error("injected primary write failure");
      }
      setState(next);
    },
  });
  const result = controllerFor(harness).apply([ownedA]);
  assert.equal(result.ok, false);
  assert.equal(result.reason, "write-failed");
  assert.equal(result.cleanup.ok, true);
  assert.deepEqual(harness.state(), [user, concurrent]);
  assert.equal(harness.reads(), 3, "initial, fresh cleanup read, cleanup readback");
  assert.equal(harness.writes.length, 2);
});

for (const scenario of [
  {
    name: "missing owned entry",
    mutate: ([user]) => [user, ownedA],
  },
  {
    name: "reordered owned entries",
    mutate: ([user]) => [user, ownedB, ownedA],
  },
  {
    name: "extra owned entry",
    mutate: ([user]) => [user, ownedA, ownedB, ownedC],
  },
  {
    name: "changed non-owned entry",
    mutate: () => ["/tmp/replaced-concurrently.glsl", ownedA, ownedB],
  },
]) {
  test(`readback ${scenario.name} fails closed`, () => {
    const user = "/tmp/user.glsl";
    const harness = makeHarness([user], {
      read({ reads, state, setState }) {
        if (reads === 2) {
          const mutated = scenario.mutate(state.slice());
          setState(mutated);
          return mutated.slice();
        }
        return state.slice();
      },
      write({ next, setState }) { setState(next); },
    });
    const result = controllerFor(harness).apply([ownedA, ownedB]);
    assert.equal(result.ok, false);
    assert.equal(result.reason, "readback-mismatch");
    assert.equal(harness.state().some((path) => ownership.owns(path)), false);
  });
}

test("a reentrant newer generation invalidates stale readback work", () => {
  const user = "/tmp/user.glsl";
  let state = [user];
  let reads = 0;
  let reentered = false;
  let innerResult;
  const writes = [];
  let controller;

  controller = new reconcile.Reconciler({
    ownership,
    read() {
      reads += 1;
      if (reads === 2 && !reentered) {
        reentered = true;
        innerResult = controller.apply([ownedB]);
      }
      return state.slice();
    },
    write(next) {
      writes.push(next.slice());
      state = next.slice();
    },
  });

  const outerResult = controller.apply([ownedA]);
  assert.equal(innerResult.ok, true);
  assert.equal(outerResult.ok, false);
  assert.equal(outerResult.stale, true);
  assert.equal(outerResult.reason, "superseded-by-newer-generation");
  assert.deepEqual(state, [user, ownedB], "stale outer operation never cleans newer owned state");
  assert.equal(writes.length, 2);
});

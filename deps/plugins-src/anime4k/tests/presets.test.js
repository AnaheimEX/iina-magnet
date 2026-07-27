"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const pluginRoot = path.resolve(__dirname, "..");
const auditManifest = JSON.parse(fs.readFileSync(path.join(pluginRoot, "manifest.json"), "utf8"));
const bundle = require(path.join(pluginRoot, "lib", "shader-bundle.js"));
const presets = require(path.join(pluginRoot, "lib", "presets.js"));

const expected = {
  fast: {
    A: ["Anime4K_Clamp_Highlights", "Anime4K_Restore_CNN_M", "Anime4K_Upscale_CNN_x2_M", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Upscale_CNN_x2_S"],
    "A+A": ["Anime4K_Clamp_Highlights", "Anime4K_Restore_CNN_M", "Anime4K_Upscale_CNN_x2_M", "Anime4K_Restore_CNN_S", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Upscale_CNN_x2_S"],
    B: ["Anime4K_Clamp_Highlights", "Anime4K_Restore_CNN_Soft_M", "Anime4K_Upscale_CNN_x2_M", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Upscale_CNN_x2_S"],
    "B+B": ["Anime4K_Clamp_Highlights", "Anime4K_Restore_CNN_Soft_M", "Anime4K_Upscale_CNN_x2_M", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Restore_CNN_Soft_S", "Anime4K_Upscale_CNN_x2_S"],
    C: ["Anime4K_Clamp_Highlights", "Anime4K_Upscale_Denoise_CNN_x2_M", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Upscale_CNN_x2_S"],
    "C+A": ["Anime4K_Clamp_Highlights", "Anime4K_Upscale_Denoise_CNN_x2_M", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Restore_CNN_S", "Anime4K_Upscale_CNN_x2_S"],
  },
  hq: {
    A: ["Anime4K_Clamp_Highlights", "Anime4K_Restore_CNN_VL", "Anime4K_Upscale_CNN_x2_VL", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Upscale_CNN_x2_M"],
    "A+A": ["Anime4K_Clamp_Highlights", "Anime4K_Restore_CNN_VL", "Anime4K_Upscale_CNN_x2_VL", "Anime4K_Restore_CNN_M", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Upscale_CNN_x2_M"],
    B: ["Anime4K_Clamp_Highlights", "Anime4K_Restore_CNN_Soft_VL", "Anime4K_Upscale_CNN_x2_VL", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Upscale_CNN_x2_M"],
    "B+B": ["Anime4K_Clamp_Highlights", "Anime4K_Restore_CNN_Soft_VL", "Anime4K_Upscale_CNN_x2_VL", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Restore_CNN_Soft_M", "Anime4K_Upscale_CNN_x2_M"],
    C: ["Anime4K_Clamp_Highlights", "Anime4K_Upscale_Denoise_CNN_x2_VL", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Upscale_CNN_x2_M"],
    "C+A": ["Anime4K_Clamp_Highlights", "Anime4K_Upscale_Denoise_CNN_x2_VL", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Restore_CNN_M", "Anime4K_Upscale_CNN_x2_M"],
  },
  off: [],
};

test("the audit and runtime manifests are identical", () => {
  assert.deepEqual(bundle.manifest, auditManifest);
  assert.deepEqual(presets, auditManifest.presets);
});

test("Fast and HQ expose all six explicit upstream chains", () => {
  assert.deepEqual(presets, expected);
  assert.deepEqual(Object.keys(presets.fast), ["A", "A+A", "B", "B+B", "C", "C+A"]);
  assert.deepEqual(Object.keys(presets.hq), ["A", "A+A", "B", "B+B", "C", "C+A"]);
});

test("Off always resolves to an empty owned chain", () => {
  assert.deepEqual(presets.off, []);
});

test("every preset references the unique reviewed shader allow-list", () => {
  const ids = auditManifest.shaders.map((shader) => shader.id);
  assert.equal(ids.length, 14);
  assert.equal(new Set(ids).size, ids.length);
  assert.deepEqual(auditManifest.shaders.map((shader) => shader.order), [...Array(14).keys()]);
  for (const tier of ["fast", "hq"]) {
    for (const chain of Object.values(presets[tier])) {
      assert.equal(new Set(chain).size, chain.length);
      for (const id of chain) assert.ok(ids.includes(id), `${tier} references unknown shader ${id}`);
    }
  }
});

test("the reviewed shader set records twelve MIT and two Unlicense files", () => {
  const byLicense = auditManifest.shaders.reduce((groups, shader) => {
    (groups[shader.license] ||= []).push(shader);
    return groups;
  }, {});
  assert.equal(byLicense.MIT.length, 12);
  assert.deepEqual(
    byLicense.Unlicense.map((shader) => shader.id).sort(),
    ["Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4"],
  );
  assert.deepEqual(auditManifest.upstream.licenses, ["MIT", "Unlicense"]);
});

test("the CommonJS payload preserves every raw UTF-8 shader byte", () => {
  assert.deepEqual(Object.keys(bundle.shaders), auditManifest.shaders.map((shader) => shader.id).sort());
  for (const shader of auditManifest.shaders) {
    const raw = fs.readFileSync(path.join(pluginRoot, "shaders", shader.file));
    const bundled = Buffer.from(bundle.shaders[shader.id], "utf8");
    assert.equal(bundled.length, shader.size, `${shader.file} size`);
    assert.equal(crypto.createHash("sha256").update(bundled).digest("hex"), shader.sha256, `${shader.file} hash`);
    assert.deepEqual(bundled, raw, `${shader.file} bytes`);
  }
});

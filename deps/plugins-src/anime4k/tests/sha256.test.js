"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const test = require("node:test");

const sha256 = require("../lib/sha256.js");

function nodeDigest(text) {
  return crypto.createHash("sha256").update(Buffer.from(text, "utf8")).digest("hex");
}

const fixtures = [
  ["empty", ""],
  ["ASCII", "Anime4K shader bundle"],
  ["known vector", "abc"],
  ["CRLF", "line one\r\nline two\r\n"],
  ["trailing newline", "last line is significant\n"],
  ["CJK and spaces", "着色器 路径/日本語/한국어.glsl"],
  ["astral Unicode", "GPU 🚀 🎞️ 😀"],
  ["combining marks", "e\u0301 is not \u00e9"],
  ["colon path", "/Users/动画:Anime4K/shader file.glsl"],
  ["unpaired high surrogate", "before\ud800after"],
  ["unpaired low surrogate", "before\udc00after"],
  ["multi-block", "0123456789abcdef".repeat(1000)],
];

test("utf8Bytes and utf8Size match Node UTF-8 fixtures", () => {
  for (const [name, text] of fixtures) {
    const expected = Buffer.from(text, "utf8");
    assert.deepEqual(Buffer.from(sha256.utf8Bytes(text)), expected, `${name} bytes`);
    assert.equal(sha256.utf8Size(text), expected.length, `${name} size`);
  }
});

test("sha256Hex matches Node crypto for ASCII, Unicode, CRLF, and final newlines", () => {
  for (const [name, text] of fixtures) {
    assert.equal(sha256.sha256Hex(text), nodeDigest(text), name);
  }
});

test("sha256Hex matches published short SHA-256 vectors", () => {
  assert.equal(
    sha256.sha256Hex(""),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  );
  assert.equal(
    sha256.sha256Hex("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  );
});

test("helpers reject non-string input instead of silently coercing", () => {
  for (const value of [null, undefined, 42, {}, ["text"]]) {
    assert.throws(() => sha256.utf8Bytes(value), TypeError);
    assert.throws(() => sha256.utf8Size(value), TypeError);
    assert.throws(() => sha256.sha256Hex(value), TypeError);
  }
});

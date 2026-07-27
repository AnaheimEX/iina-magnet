"use strict";

// Dependency-free UTF-8 and SHA-256 helpers for JavaScriptCore. Keep this file
// ES5-compatible: it is loaded by the plugin at runtime, not only by Node tests.

var SHA256_CONSTANTS = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];

function requireString(text) {
  if (typeof text !== "string") {
    throw new TypeError("SHA-256 input must be a string");
  }
}

function appendCodePoint(bytes, codePoint) {
  if (codePoint < 0x80) {
    bytes.push(codePoint);
  } else if (codePoint < 0x800) {
    bytes.push(0xc0 | (codePoint >>> 6));
    bytes.push(0x80 | (codePoint & 0x3f));
  } else if (codePoint < 0x10000) {
    bytes.push(0xe0 | (codePoint >>> 12));
    bytes.push(0x80 | ((codePoint >>> 6) & 0x3f));
    bytes.push(0x80 | (codePoint & 0x3f));
  } else {
    bytes.push(0xf0 | (codePoint >>> 18));
    bytes.push(0x80 | ((codePoint >>> 12) & 0x3f));
    bytes.push(0x80 | ((codePoint >>> 6) & 0x3f));
    bytes.push(0x80 | (codePoint & 0x3f));
  }
}

function utf8Bytes(text) {
  requireString(text);
  var bytes = [];
  var index;
  for (index = 0; index < text.length; index += 1) {
    var code = text.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      if (index + 1 < text.length) {
        var low = text.charCodeAt(index + 1);
        if (low >= 0xdc00 && low <= 0xdfff) {
          appendCodePoint(bytes, 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00));
          index += 1;
          continue;
        }
      }
      appendCodePoint(bytes, 0xfffd);
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      appendCodePoint(bytes, 0xfffd);
    } else {
      appendCodePoint(bytes, code);
    }
  }
  return bytes;
}

function utf8Size(text) {
  return utf8Bytes(text).length;
}

function rotateRight(value, bits) {
  return (value >>> bits) | (value << (32 - bits));
}

function wordHex(value) {
  var result = "";
  var shift;
  for (shift = 28; shift >= 0; shift -= 4) {
    result += ((value >>> shift) & 0x0f).toString(16);
  }
  return result;
}

function sha256Hex(text) {
  var bytes = utf8Bytes(text);
  var byteLength = bytes.length;
  var highBitLength = Math.floor(byteLength / 0x20000000);
  var lowBitLength = (byteLength << 3) >>> 0;

  bytes.push(0x80);
  while ((bytes.length % 64) !== 56) {
    bytes.push(0);
  }
  bytes.push((highBitLength >>> 24) & 0xff);
  bytes.push((highBitLength >>> 16) & 0xff);
  bytes.push((highBitLength >>> 8) & 0xff);
  bytes.push(highBitLength & 0xff);
  bytes.push((lowBitLength >>> 24) & 0xff);
  bytes.push((lowBitLength >>> 16) & 0xff);
  bytes.push((lowBitLength >>> 8) & 0xff);
  bytes.push(lowBitLength & 0xff);

  var hash = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  ];
  var schedule = new Array(64);
  var offset;

  for (offset = 0; offset < bytes.length; offset += 64) {
    var index;
    for (index = 0; index < 16; index += 1) {
      var wordOffset = offset + (index * 4);
      schedule[index] = (
        (bytes[wordOffset] << 24) |
        (bytes[wordOffset + 1] << 16) |
        (bytes[wordOffset + 2] << 8) |
        bytes[wordOffset + 3]
      ) >>> 0;
    }
    for (index = 16; index < 64; index += 1) {
      var previous15 = schedule[index - 15];
      var previous2 = schedule[index - 2];
      var sigma0 = rotateRight(previous15, 7) ^ rotateRight(previous15, 18) ^ (previous15 >>> 3);
      var sigma1 = rotateRight(previous2, 17) ^ rotateRight(previous2, 19) ^ (previous2 >>> 10);
      schedule[index] = (schedule[index - 16] + sigma0 + schedule[index - 7] + sigma1) >>> 0;
    }

    var a = hash[0];
    var b = hash[1];
    var c = hash[2];
    var d = hash[3];
    var e = hash[4];
    var f = hash[5];
    var g = hash[6];
    var h = hash[7];

    for (index = 0; index < 64; index += 1) {
      var upperSigma1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
      var choice = (e & f) ^ ((~e) & g);
      var temporary1 = (h + upperSigma1 + choice + SHA256_CONSTANTS[index] + schedule[index]) >>> 0;
      var upperSigma0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
      var majority = (a & b) ^ (a & c) ^ (b & c);
      var temporary2 = (upperSigma0 + majority) >>> 0;

      h = g;
      g = f;
      f = e;
      e = (d + temporary1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (temporary1 + temporary2) >>> 0;
    }

    hash[0] = (hash[0] + a) >>> 0;
    hash[1] = (hash[1] + b) >>> 0;
    hash[2] = (hash[2] + c) >>> 0;
    hash[3] = (hash[3] + d) >>> 0;
    hash[4] = (hash[4] + e) >>> 0;
    hash[5] = (hash[5] + f) >>> 0;
    hash[6] = (hash[6] + g) >>> 0;
    hash[7] = (hash[7] + h) >>> 0;
  }

  return wordHex(hash[0]) + wordHex(hash[1]) + wordHex(hash[2]) + wordHex(hash[3]) +
    wordHex(hash[4]) + wordHex(hash[5]) + wordHex(hash[6]) + wordHex(hash[7]);
}

module.exports = {
  utf8Bytes: utf8Bytes,
  utf8Size: utf8Size,
  sha256Hex: sha256Hex
};

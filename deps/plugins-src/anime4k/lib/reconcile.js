"use strict";

// Pure ownership/list helpers plus a synchronous, injectable reconciler. This
// runtime module intentionally uses ES5 syntax and has no Node dependencies.

var ownProperty = Object.prototype.hasOwnProperty;

function requireNativeArray(value, label) {
  var name = label || "glsl-shaders";
  if (!Array.isArray(value)) {
    throw new TypeError(name + " must be a native array; string fallback is forbidden");
  }
  var copy = new Array(value.length);
  var index;
  for (index = 0; index < value.length; index += 1) {
    if (typeof value[index] !== "string") {
      throw new TypeError(name + "[" + index + "] must be a string");
    }
    copy[index] = value[index];
  }
  return copy;
}

function requireAbsoluteOwnedPath(path, label) {
  if (path.length < 2 || path.charAt(0) !== "/") {
    throw new TypeError(label + " must be an absolute file path");
  }
  if (path.indexOf("\u0000") !== -1) {
    throw new TypeError(label + " must not contain NUL");
  }
  var components = path.split("/");
  var index;
  for (index = 1; index < components.length; index += 1) {
    if (components[index] === "" || components[index] === "." || components[index] === "..") {
      throw new TypeError(label + " must already be a canonical absolute path");
    }
  }
}

function addOwnershipPaths(target, lookup, paths, label) {
  var checked = requireNativeArray(paths, label);
  var index;
  for (index = 0; index < checked.length; index += 1) {
    var path = checked[index];
    requireAbsoluteOwnedPath(path, label + "[" + index + "]");
    if (!ownProperty.call(lookup, path)) {
      lookup[path] = true;
      target.push(path);
    }
  }
  return checked;
}

function createOwnership(currentAbsolutePaths, retainedAbsolutePaths) {
  var lookup = Object.create(null);
  var all = [];
  var current = addOwnershipPaths(all, lookup, currentAbsolutePaths, "current owned paths");
  var retained = addOwnershipPaths(
    all,
    lookup,
    retainedAbsolutePaths === undefined ? [] : retainedAbsolutePaths,
    "retained owned paths"
  );

  return {
    current: current,
    retained: retained,
    paths: all,
    owns: function (path) {
      return typeof path === "string" && ownProperty.call(lookup, path);
    }
  };
}

function requireOwnership(ownership) {
  if (!ownership || typeof ownership.owns !== "function" || !Array.isArray(ownership.paths)) {
    throw new TypeError("ownership must be created by createOwnership");
  }
  return ownership;
}

function stripOwned(current, ownership) {
  var list = requireNativeArray(current, "current glsl-shaders");
  var owner = requireOwnership(ownership);
  var stripped = [];
  var index;
  for (index = 0; index < list.length; index += 1) {
    if (!owner.owns(list[index])) {
      stripped.push(list[index]);
    }
  }
  return stripped;
}

function requireDesiredOwned(desiredOwned, ownership) {
  var desired = requireNativeArray(desiredOwned, "desired owned shaders");
  var owner = requireOwnership(ownership);
  var index;
  for (index = 0; index < desired.length; index += 1) {
    if (!owner.owns(desired[index])) {
      throw new TypeError("desired owned shader is not in the exact ownership set: " + desired[index]);
    }
  }
  return desired;
}

function merge(current, ownership, desiredOwned) {
  var desired = requireDesiredOwned(desiredOwned, ownership);
  return stripOwned(current, ownership).concat(desired);
}

function verify(expected, actual) {
  if (!Array.isArray(expected) || !Array.isArray(actual) || expected.length !== actual.length) {
    return false;
  }
  var index;
  for (index = 0; index < expected.length; index += 1) {
    if (typeof expected[index] !== "string" || typeof actual[index] !== "string" || expected[index] !== actual[index]) {
      return false;
    }
  }
  return true;
}

function errorMessage(error) {
  if (error && typeof error.message === "string") {
    return error.message;
  }
  return String(error);
}

function staleResult(operation, generation) {
  return {
    ok: false,
    stale: true,
    changed: false,
    operation: operation,
    generation: generation,
    reason: "superseded-by-newer-generation"
  };
}

function failedResult(operation, generation, reason, error, cleanup) {
  var result = {
    ok: false,
    stale: false,
    changed: false,
    operation: operation,
    generation: generation,
    reason: reason,
    cleanup: cleanup || null
  };
  if (error !== undefined && error !== null) {
    result.error = errorMessage(error);
  }
  return result;
}

function Reconciler(options) {
  if (!(this instanceof Reconciler)) {
    return new Reconciler(options);
  }
  if (!options || typeof options !== "object") {
    throw new TypeError("Reconciler options are required");
  }

  var property = options.property || "glsl-shaders";
  if (typeof options.read === "function" && typeof options.write === "function") {
    this._read = options.read;
    this._write = options.write;
  } else if (options.mpv && typeof options.mpv.getNative === "function" && typeof options.mpv.set === "function") {
    this._read = function () {
      return options.mpv.getNative(property);
    };
    this._write = function (value) {
      options.mpv.set(property, value);
    };
  } else {
    throw new TypeError("Reconciler requires synchronous read/write functions or an mpv adapter");
  }

  this.ownership = requireOwnership(options.ownership);
  this._generation = 0;
}

Reconciler.prototype._isCurrent = function (generation) {
  return this._generation === generation;
};

Reconciler.prototype._readNative = function () {
  return requireNativeArray(this._read(), "glsl-shaders");
};

Reconciler.prototype._cleanupAfterFailure = function (generation, operation, reason, error) {
  if (!this._isCurrent(generation)) {
    return staleResult(operation, generation);
  }

  var latest;
  try {
    latest = this._readNative();
  } catch (cleanupReadError) {
    return failedResult(operation, generation, reason, error, {
      ok: false,
      changed: false,
      reason: "cleanup-read-failed",
      error: errorMessage(cleanupReadError)
    });
  }
  if (!this._isCurrent(generation)) {
    return staleResult(operation, generation);
  }

  var cleaned = stripOwned(latest, this.ownership);
  var removedOwned = !verify(latest, cleaned);

  var cleanupWriteError = null;
  try {
    this._write(cleaned.slice());
  } catch (writeError) {
    cleanupWriteError = writeError;
  }
  if (!this._isCurrent(generation)) {
    return staleResult(operation, generation);
  }

  var cleanupActual;
  try {
    cleanupActual = this._readNative();
  } catch (cleanupReadbackError) {
    return failedResult(operation, generation, reason, error, {
      ok: false,
      changed: true,
      expected: cleaned,
      reason: "cleanup-readback-failed",
      writeError: cleanupWriteError === null ? null : errorMessage(cleanupWriteError),
      error: errorMessage(cleanupReadbackError)
    });
  }
  if (!this._isCurrent(generation)) {
    return staleResult(operation, generation);
  }

  var cleanupOK = cleanupWriteError === null && verify(cleaned, cleanupActual);
  return failedResult(operation, generation, reason, error, {
    ok: cleanupOK,
    changed: removedOwned,
    expected: cleaned,
    actual: cleanupActual,
    reason: cleanupOK ? null : "cleanup-verification-failed",
    writeError: cleanupWriteError === null ? null : errorMessage(cleanupWriteError)
  });
};

Reconciler.prototype._run = function (desiredOwned, operation) {
  var desired;
  try {
    desired = requireDesiredOwned(desiredOwned, this.ownership);
  } catch (desiredError) {
    return failedResult(operation, this._generation, "invalid-desired-owned-chain", desiredError, null);
  }

  var generation = this._generation + 1;
  this._generation = generation;

  var current;
  try {
    current = this._readNative();
  } catch (readError) {
    return this._cleanupAfterFailure(generation, operation, "initial-read-failed", readError);
  }
  if (!this._isCurrent(generation)) {
    return staleResult(operation, generation);
  }

  var expected = merge(current, this.ownership, desired);
  if (verify(current, expected)) {
    return {
      ok: true,
      stale: false,
      changed: false,
      operation: operation,
      generation: generation,
      expected: expected,
      actual: current
    };
  }

  try {
    this._write(expected.slice());
  } catch (writeError) {
    if (!this._isCurrent(generation)) {
      return staleResult(operation, generation);
    }
    return this._cleanupAfterFailure(generation, operation, "write-failed", writeError);
  }
  if (!this._isCurrent(generation)) {
    return staleResult(operation, generation);
  }

  var actual;
  try {
    actual = this._readNative();
  } catch (readbackError) {
    return this._cleanupAfterFailure(generation, operation, "readback-failed", readbackError);
  }
  if (!this._isCurrent(generation)) {
    return staleResult(operation, generation);
  }

  if (!verify(expected, actual)) {
    return this._cleanupAfterFailure(generation, operation, "readback-mismatch", null);
  }

  return {
    ok: true,
    stale: false,
    changed: true,
    operation: operation,
    generation: generation,
    expected: expected,
    actual: actual
  };
};

Reconciler.prototype.apply = function (desiredOwned) {
  return this._run(desiredOwned, "apply");
};

Reconciler.prototype.cleanup = function () {
  return this._run([], "cleanup");
};

Reconciler.prototype.disable = function () {
  return this._run([], "disable");
};

Reconciler.prototype.unload = function () {
  return this._run([], "unload");
};

Reconciler.prototype.invalidate = function () {
  this._generation += 1;
  return this._generation;
};

module.exports = {
  requireNativeArray: requireNativeArray,
  createOwnership: createOwnership,
  stripOwned: stripOwned,
  merge: merge,
  verify: verify,
  Reconciler: Reconciler
};

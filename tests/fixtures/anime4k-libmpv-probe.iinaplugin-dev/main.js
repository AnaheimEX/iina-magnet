(function () {
  "use strict";

  var propertyName = "glsl-shaders";
  var startedAt = Date.now();
  var errors = [];

  function preference(key) {
    return iina.preferences.get(key);
  }

  function cloneArray(value) {
    return Array.isArray(value) ? Array.prototype.slice.call(value) : value;
  }

  function arraysEqual(left, right) {
    if (!Array.isArray(left) || !Array.isArray(right) || left.length !== right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] !== right[index]) {
        return false;
      }
    }
    return true;
  }

  function valueType(value) {
    if (Array.isArray(value)) {
      return "array";
    }
    if (value === null) {
      return "null";
    }
    return typeof value;
  }

  function count(array, value) {
    if (!Array.isArray(array)) {
      return 0;
    }
    var total = 0;
    for (var index = 0; index < array.length; index += 1) {
      if (array[index] === value) {
        total += 1;
      }
    }
    return total;
  }

  function stringValue(value) {
    return value === null || value === undefined ? "" : String(value);
  }

  var runId = stringValue(preference("run_id"));
  var appPath = stringValue(preference("app_path"));
  var inputArray = cloneArray(preference("input_array"));
  var ownedPaths = cloneArray(preference("owned_paths"));
  var latestStateArray = cloneArray(preference("latest_state_array"));
  var expectedCleanupArray = cloneArray(preference("expected_cleanup_array"));
  var featurePaths = preference("feature_paths") || {};
  var versions = iina.core.getVersion() || {};
  var nativePropertyType = "unread";
  var readbackArray = null;
  var latestStateReadbackArray = null;
  var cleanupSourceArray = null;
  var latestStateCleanupReadback = null;

  try {
    if (!Array.isArray(inputArray) || !Array.isArray(ownedPaths) ||
        !Array.isArray(latestStateArray) || !Array.isArray(expectedCleanupArray)) {
      throw new Error("Probe preferences must contain array values");
    }

    iina.mpv.set(propertyName, inputArray);
    var nativeReadback = iina.mpv.getNative(propertyName);
    nativePropertyType = valueType(nativeReadback);
    readbackArray = cloneArray(nativeReadback);

    iina.mpv.set(propertyName, latestStateArray);
    var latestNativeReadback = iina.mpv.getNative(propertyName);
    latestStateReadbackArray = cloneArray(latestNativeReadback);

    if (Array.isArray(latestNativeReadback)) {
      // Cleanup deliberately uses a fresh read, never the earlier input snapshot.
      cleanupSourceArray = cloneArray(latestNativeReadback);
      var cleaned = cleanupSourceArray.filter(function (path) {
        return ownedPaths.indexOf(path) === -1;
      });
      iina.mpv.set(propertyName, cleaned);
      latestStateCleanupReadback = cloneArray(iina.mpv.getNative(propertyName));
    } else {
      errors.push("latest getNative(glsl-shaders) value is not an array");
    }
  } catch (error) {
    errors.push(stringValue(error && error.message ? error.message : error));
  }

  var checks = {
    native_array: nativePropertyType === "array",
    exact_round_trip: arraysEqual(inputArray, readbackArray),
    space_preserved: Array.isArray(readbackArray) &&
      readbackArray.indexOf(featurePaths.space) === inputArray.indexOf(featurePaths.space),
    unicode_preserved: Array.isArray(readbackArray) &&
      readbackArray.indexOf(featurePaths.unicode) === inputArray.indexOf(featurePaths.unicode),
    colon_preserved: Array.isArray(readbackArray) &&
      readbackArray.indexOf(featurePaths.colon) === inputArray.indexOf(featurePaths.colon),
    duplicate_preserved: count(inputArray, featurePaths.duplicate) >= 2 &&
      count(readbackArray, featurePaths.duplicate) === count(inputArray, featurePaths.duplicate),
    order_preserved: arraysEqual(inputArray, readbackArray),
    latest_state_reread_exact: arraysEqual(latestStateArray, latestStateReadbackArray) &&
      arraysEqual(latestStateReadbackArray, cleanupSourceArray),
    owned_cleanup_exact: arraysEqual(expectedCleanupArray, latestStateCleanupReadback),
    non_owned_preserved: arraysEqual(expectedCleanupArray, latestStateCleanupReadback)
  };

  Object.keys(checks).forEach(function (name) {
    if (!checks[name]) {
      errors.push("check failed: " + name);
    }
  });

  var result = {
    schema_version: 1,
    run_id: runId,
    timestamp: new Date().toISOString(),
    app: {
      path: appPath,
      version: stringValue(versions.iina),
      build: stringValue(versions.build)
    },
    libmpv_version: stringValue(versions.mpv),
    native_property: propertyName,
    native_property_type: nativePropertyType,
    input_array: inputArray,
    readback_array: readbackArray,
    owned_paths: ownedPaths,
    latest_state_input_array: latestStateArray,
    latest_state_readback_array: latestStateReadbackArray,
    cleanup_source_array: cleanupSourceArray,
    expected_cleanup_array: expectedCleanupArray,
    latest_state_cleanup_readback: latestStateCleanupReadback,
    elapsed_ms: Date.now() - startedAt,
    checks: checks,
    verdict: errors.length === 0 ? "pass" : "contract-fail",
    errors: errors
  };

  iina.file.write("@data/probe-result.json", JSON.stringify(result, null, 2));
}());

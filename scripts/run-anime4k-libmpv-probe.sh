#!/bin/bash

set -uo pipefail

EXIT_CONTRACT_FAILURE=2
EXIT_TIMEOUT=3
EXIT_HARNESS_FAILURE=4
MAX_TIMEOUT=45

usage() {
  cat <<'EOF'
Usage: scripts/run-anime4k-libmpv-probe.sh --app IINA.app [--timeout SECONDS] --output FILE

Runs the repository-owned dev plugin against the specified app's bundled
libmpv using an isolated HOME, CFFIXED_USER_HOME, and TMPDIR.

Exit codes:
  0  contract passed
  2  contract failed
  3  timed out
  4  harness error or app exited before producing evidence
EOF
}

app_path=""
output_path=""
timeout_seconds="$MAX_TIMEOUT"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)
      [ "$#" -ge 2 ] || { usage >&2; exit "$EXIT_HARNESS_FAILURE"; }
      app_path="$2"
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || { usage >&2; exit "$EXIT_HARNESS_FAILURE"; }
      output_path="$2"
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || { usage >&2; exit "$EXIT_HARNESS_FAILURE"; }
      timeout_seconds="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit "$EXIT_HARNESS_FAILURE"
      ;;
  esac
done

if [ -z "$app_path" ] || [ -z "$output_path" ]; then
  usage >&2
  exit "$EXIT_HARNESS_FAILURE"
fi
case "$timeout_seconds" in
  ''|*[!0-9]*)
    echo "--timeout must be an integer from 1 to $MAX_TIMEOUT" >&2
    exit "$EXIT_HARNESS_FAILURE"
    ;;
esac
if [ "$timeout_seconds" -lt 1 ] || [ "$timeout_seconds" -gt "$MAX_TIMEOUT" ]; then
  echo "--timeout must be an integer from 1 to $MAX_TIMEOUT" >&2
  exit "$EXIT_HARNESS_FAILURE"
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
validator="$script_dir/anime4k_libmpv_probe_validator.py"
fixture="$repo_root/tests/fixtures/anime4k-libmpv-probe.iinaplugin-dev"
app_parent="$(cd "$(dirname "$app_path")" 2>/dev/null && pwd)" || {
  echo "IINA app parent directory not found: $app_path" >&2
  exit "$EXIT_HARNESS_FAILURE"
}
app_path="$app_parent/$(basename "$app_path")"
app_binary="$app_path/Contents/MacOS/IINA"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required for the standard-library-only probe validator" >&2
  exit "$EXIT_HARNESS_FAILURE"
fi
if [ ! -x "$app_binary" ]; then
  echo "IINA executable not found: $app_binary" >&2
  exit "$EXIT_HARNESS_FAILURE"
fi
if [ ! -f "$validator" ] || [ ! -d "$fixture" ]; then
  echo "Repository probe files are missing" >&2
  exit "$EXIT_HARNESS_FAILURE"
fi

case "$output_path" in
  /*) ;;
  *) output_path="$PWD/$output_path" ;;
esac
mkdir -p "$(dirname "$output_path")" || exit "$EXIT_HARNESS_FAILURE"

run_root="$(mktemp -d "${TMPDIR:-/tmp}/iina-anime4k-probe.XXXXXX")" || exit "$EXIT_HARNESS_FAILURE"
app_pid=""

stop_app() {
  if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait_ticks=0
    while kill -0 "$app_pid" 2>/dev/null && [ "$wait_ticks" -lt 20 ]; do
      sleep 0.1
      wait_ticks=$((wait_ticks + 1))
    done
    if kill -0 "$app_pid" 2>/dev/null; then
      kill -KILL "$app_pid" 2>/dev/null || true
    fi
  fi
  if [ -n "$app_pid" ]; then
    wait "$app_pid" 2>/dev/null || true
  fi
}

cleanup() {
  stop_app
  rm -rf "$run_root"
}
trap cleanup EXIT HUP INT TERM

if ! python3 "$validator" prepare \
  --root "$run_root" \
  --fixture "$fixture" \
  --app "$app_path" \
  --timeout "$timeout_seconds"; then
  exit "$EXIT_HARNESS_FAILURE"
fi

expected="$run_root/expected.json"
plugin_result="$(cat "$run_root/result-path.txt")"
app_log="$run_root/app.log"
started_epoch="$(date +%s)"

env \
  HOME="$run_root/home" \
  CFFIXED_USER_HOME="$run_root/home" \
  TMPDIR="$run_root/tmp" \
  "$app_binary" "-PluginEnabled.io.iina.anime4k.libmpv-probe" YES >"$app_log" 2>&1 &
app_pid=$!

while [ ! -f "$plugin_result" ]; do
  if ! kill -0 "$app_pid" 2>/dev/null; then
    wait "$app_pid" 2>/dev/null
    app_status=$?
    elapsed_ms=$((($(date +%s) - started_epoch) * 1000))
    python3 "$validator" failure \
      --expected "$expected" \
      --output "$output_path" \
      --verdict harness-error \
      --message "IINA exited before producing probe evidence (status $app_status)" \
      --elapsed-ms "$elapsed_ms" >/dev/null 2>&1 || true
    echo "IINA exited before producing probe evidence (status $app_status)" >&2
    tail -n 40 "$app_log" >&2 || true
    exit "$EXIT_HARNESS_FAILURE"
  fi
  elapsed_seconds=$(($(date +%s) - started_epoch))
  if [ "$elapsed_seconds" -ge "$timeout_seconds" ]; then
    python3 "$validator" failure \
      --expected "$expected" \
      --output "$output_path" \
      --verdict timeout \
      --message "probe timed out after $timeout_seconds seconds" \
      --elapsed-ms "$((elapsed_seconds * 1000))" >/dev/null 2>&1 || true
    echo "Anime4K libmpv probe timed out after $timeout_seconds seconds" >&2
    tail -n 40 "$app_log" >&2 || true
    exit "$EXIT_TIMEOUT"
  fi
  sleep 0.1
done

python3 "$validator" validate \
  --input "$plugin_result" \
  --expected "$expected" \
  --output "$output_path"
validator_status=$?

case "$validator_status" in
  0)
    echo "Anime4K libmpv contract probe passed: $output_path"
    exit 0
    ;;
  2)
    echo "Anime4K libmpv contract probe failed: $output_path" >&2
    exit "$EXIT_CONTRACT_FAILURE"
    ;;
  *)
    echo "Anime4K libmpv probe validator failed (status $validator_status)" >&2
    exit "$EXIT_HARNESS_FAILURE"
    ;;
esac

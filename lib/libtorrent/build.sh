#!/bin/bash
#
# build.sh
# Compile libtorrent (Rasterbar) 2.0.x as a macOS universal static library.
#
# Output:
#   lib/libtorrent/include/libtorrent/...        (headers)
#   lib/libtorrent/lib/libtorrent-rasterbar.a    (arm64+x86_64 universal static)
#
# Inputs are downloaded once and cached under build/sources/.
# Re-running this script after a successful run is a no-op (idempotent).
#
# See ADR-0002 (libtorrent 进程内桥接) and Issue 04 in planning branch.
#
# Usage:
#   cd <repo root>
#   ./lib/libtorrent/build.sh

set -euo pipefail

# ---- Pinned versions (do not change without bumping ADR-0002) ----
readonly LIBTORRENT_VERSION="2.0.10"
readonly BOOST_VERSION="1.84.0"
readonly DEPLOYMENT_TARGET="14.0"
readonly ARCHS=("arm64" "x86_64")

# ---- Paths ----
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILD_DIR="$SCRIPT_DIR/build"
readonly SRC_DIR="$BUILD_DIR/sources"
readonly OUT_INCLUDE="$SCRIPT_DIR/include"
readonly OUT_LIB="$SCRIPT_DIR/lib"
readonly LIBTORRENT_SRC="$SRC_DIR/libtorrent-rasterbar-$LIBTORRENT_VERSION"
readonly BOOST_SRC="$SRC_DIR/boost"

# ---- Colors ----
readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly BLUE=$'\033[0;34m'
readonly NC=$'\033[0m'

log()  { echo -e "${BLUE}==>${NC} $*" >&2; }
ok()   { echo -e "${GREEN}✓${NC}  $*" >&2; }
err()  { echo -e "${RED}✗${NC}  $*" >&2; }

# ---- Skip if final artifact already present and up to date ----
readonly STAMP="$OUT_LIB/.built-$LIBTORRENT_VERSION-$BOOST_VERSION"
if [[ -f "$OUT_LIB/libtorrent-rasterbar.a" && -f "$STAMP" ]]; then
  ok "libtorrent $LIBTORRENT_VERSION universal static already present; nothing to do"
  ok "  $OUT_LIB/libtorrent-rasterbar.a ($(stat -f%z "$OUT_LIB/libtorrent-rasterbar.a") bytes)"
  exit 0
fi

# ---- Preflight ----
command -v cmake >/dev/null 2>&1 || { err "cmake not found. Install via: brew install cmake"; exit 1; }
command -v curl  >/dev/null 2>&1 || { err "curl not found"; exit 1; }
command -v tar   >/dev/null 2>&1 || { err "tar not found"; exit 1; }
command -v lipo  >/dev/null 2>&1 || { err "lipo not found (need Xcode CLT)"; exit 1; }

mkdir -p "$BUILD_DIR" "$SRC_DIR" "$OUT_INCLUDE" "$OUT_LIB"

# ---- 1. Download libtorrent source ----
if [[ ! -d "$LIBTORRENT_SRC" ]]; then
  log "Downloading libtorrent $LIBTORRENT_VERSION source"
  local_tarball="$SRC_DIR/libtorrent-rasterbar-$LIBTORRENT_VERSION.tar.gz"
  url="https://github.com/arvidn/libtorrent/releases/download/v$LIBTORRENT_VERSION/libtorrent-rasterbar-$LIBTORRENT_VERSION.tar.gz"
  curl -fL "$url" -o "$local_tarball"
  tar -xzf "$local_tarball" -C "$SRC_DIR"
  rm "$local_tarball"
  ok "libtorrent source extracted to $LIBTORRENT_SRC"
else
  ok "libtorrent source already present"
fi

# ---- 2. Download Boost headers ----
if [[ ! -d "$BOOST_SRC" ]]; then
  log "Downloading Boost $BOOST_VERSION headers"
  local_tarball="$SRC_DIR/boost.tar.gz"
  BOOST_UNDERSCORED="${BOOST_VERSION//./_}"
  url="https://archives.boost.io/release/$BOOST_VERSION/source/boost_$BOOST_UNDERSCORED.tar.gz"
  curl -fL "$url" -o "$local_tarball"
  tar -xzf "$local_tarball" -C "$SRC_DIR"
  mv "$SRC_DIR/boost_$BOOST_UNDERSCORED" "$BOOST_SRC"
  rm "$local_tarball"
  ok "Boost headers extracted to $BOOST_SRC"
else
  ok "Boost source already present"
fi

# ---- 3. Configure + build per arch ----
arch_libs=()
for ARCH in "${ARCHS[@]}"; do
  arch_build="$BUILD_DIR/build-$ARCH"
  log "Configuring libtorrent for $ARCH → $arch_build"
  cmake -S "$LIBTORRENT_SRC" -B "$arch_build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBoost_INCLUDE_DIR="$BOOST_SRC" \
    -Ddeprecated-functions=OFF \
    -Dpython-bindings=OFF \
    -Dbuild_tests=OFF \
    -Dbuild_examples=OFF \
    -Dencryption=ON \
    -Dexceptions=ON \
    >>"$BUILD_DIR/configure-$ARCH.log" 2>&1

  log "Building libtorrent for $ARCH (this may take 5-10 minutes)…"
  cmake --build "$arch_build" --target torrent-rasterbar -j "$(sysctl -n hw.ncpu)" \
    >>"$BUILD_DIR/build-$ARCH.log" 2>&1

  arch_lib="$arch_build/libtorrent-rasterbar.a"
  [[ -f "$arch_lib" ]] || { err "Expected $arch_lib not found after build for $ARCH"; exit 1; }
  arch_libs+=("$arch_lib")
  ok "Built $ARCH static: $(stat -f%z "$arch_lib") bytes"
done

# ---- 4. Copy headers (arch-independent) ----
log "Copying headers to $OUT_INCLUDE"
rm -rf "$OUT_INCLUDE/libtorrent"
cp -R "$LIBTORRENT_SRC/include/libtorrent" "$OUT_INCLUDE/"

# ---- 5. lipo merge ----
log "lipo merging universal static library"
lipo -create -output "$OUT_LIB/libtorrent-rasterbar.a" "${arch_libs[@]}"
lipo -info "$OUT_LIB/libtorrent-rasterbar.a"

# ---- 6. Stamp ----
touch "$STAMP"

ok "Universal static built: $OUT_LIB/libtorrent-rasterbar.a ($(stat -f%z "$OUT_LIB/libtorrent-rasterbar.a") bytes)"
ok "Headers at: $OUT_INCLUDE/libtorrent/"
ok "Done."

# libtorrent (Rasterbar)

Vendored build of [libtorrent](https://github.com/arvidn/libtorrent) **2.0.10** as a macOS universal static library, for use by the `LibtorrentBridge` Obj-C++ wrapper (Issue 05).

## Why source build

* Static linkage — no runtime dylib path concerns
* Same configure flags across dev/CI/release
* Reproducible: pinned to a specific libtorrent + boost version (see `build.sh`)
* CI cache key is just the libtorrent version

## How to build

From repo root:

```bash
./lib/libtorrent/build.sh
```

First run downloads ~140MB of source (libtorrent + Boost headers), then builds for arm64 and x86_64 and `lipo`-merges. Takes 5-15 minutes on Apple Silicon. Re-runs are no-ops (stamp file in `lib/`).

Outputs:

- `lib/libtorrent/include/libtorrent/*.hpp` — headers (arch-independent)
- `lib/libtorrent/lib/libtorrent-rasterbar.a` — universal static library

## Pinned versions

| Component | Version | Source |
| --- | --- | --- |
| libtorrent | **2.0.10** | https://github.com/arvidn/libtorrent/releases |
| Boost (headers only) | **1.84.0** | https://archives.boost.io |
| macOS deployment target | **14.0** | matches `Configs/Deployment.xcconfig` |

To bump: update constants at top of `build.sh`, write a new ADR if it's a major libtorrent version change.

## CI caching (future Issue 04+ refinement)

The GitHub Actions cache key is `libtorrent-2.0.10-boost-1.84.0`. After the first cache miss (build from scratch, ~10 min), subsequent runs restore in ~30s.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `cmake not found` | Xcode CLT alone isn't enough | `brew install cmake` |
| Download fails | Network / archives.boost.io throttling | Re-run; script resumes from cached sources |
| `Boost not found` in cmake output | Wrong Boost path | `rm -rf lib/libtorrent/build/sources/boost` and re-run |
| linker errors at iina build time | universal lib lacks one arch | Check `lipo -info lib/libtorrent/lib/libtorrent-rasterbar.a` |

## What's NOT included

* No OpenSSL — libtorrent uses internal SSL fallback (or system TLS); if a future feature needs strong encryption we'll vendor BoringSSL
* No Python bindings, no examples, no tests — pure library only
* No deprecated functions (`-Ddeprecated-functions=OFF`)

## Linking from Xcode

`LibtorrentBridge` target in `iina-magnet/` (Issue 05) declares:

* Header search path: `$(SRCROOT)/lib/libtorrent/include`
* Library search path: `$(SRCROOT)/lib/libtorrent/lib`
* Other linker flags: `-ltorrent-rasterbar`

These will be added by Issue 05's xcodeproj integration.

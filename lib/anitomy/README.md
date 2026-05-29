# Vendored Anitomy

This project vendors **Anitomy** — Eren Okka's C++ library for parsing anime
video filenames — for the Phase 2 media-library filename parser (see
[ADR-0006](../../docs/adr/0006-anitomy-bridge.md)).

- Upstream: https://github.com/erengy/anitomy
- Branch / commit: `master` @ `a538eff` ("Add keywords for audio, video, subtitles")
- Version: the classic stable C++14 API (`anitomy::Anitomy`, `string_t = std::wstring`,
  `kElementAnimeTitle` / `kElementEpisodeNumber` element categories). **Not** the
  C++23 rewrite on the `develop` branch — the classic version matches ADR-0006's
  documented element names and is far cheaper to compile inside an Obj-C++
  translation unit on Apple clang.
- License: MPL-2.0 (see `LICENSE` here; GPL-compatible).

The source `.h` / `.cpp` live under
`iina-magnet/Sources/AnitomyBridge/anitomy/` so SwiftPM compiles them as part of
the `AnitomyBridge` target. Update by re-copying that directory from the pinned
commit; do not hand-edit the vendored files.

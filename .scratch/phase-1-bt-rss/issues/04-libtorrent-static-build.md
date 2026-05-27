# Issue 04 · libtorrent 静态库编译（universal arm64+x86_64）

Status: completed (merged to develop)
Sprint: 1 (libtorrent 桥接)
Created: 2026-05-26
Updated: 2026-05-26
Related: [ADR-0002](../../../docs/adr/0002-libtorrent-inproc.md)
BlockedBy: 01
Blocks: 05

## 描述

把 libtorrent 2.0.x 编译为 macOS universal 静态库（`.a`），并固化构建脚本，供后续 Obj-C++ wrapper（Issue 05）链入。

不能依赖 `brew install libtorrent-rasterbar` 之类的开发机本地状态——CI 必须能一键 build。

## 验收标准

- [ ] `lib/libtorrent/` 目录建立：
  - `lib/libtorrent/build.sh` —— 一键脚本，arm64 + x86_64 → lipo 合并
  - `lib/libtorrent/README.md` —— 说明版本（如 `2.0.10`）、编译选项、输出位置
  - `.gitignore`：忽略 `build/` 与 `prefix/` 等中间产物
- [ ] 锁定版本：libtorrent **2.0.10**（C++17，去 Boost-system 依赖）
- [ ] 编译选项：
  - `--enable-encryption`
  - `--disable-debug`
  - `-DBUILD_SHARED_LIBS=OFF`（静态）
  - `-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0`
  - 同时编 arm64 与 x86_64，`lipo -create` 合并为 universal
- [ ] 头文件复制到 `lib/libtorrent/include/`
- [ ] 静态库输出到 `lib/libtorrent/lib/libtorrent-rasterbar.a`
- [ ] `xcodebuild` 设置 `HEADER_SEARCH_PATHS` 与 `LIBRARY_SEARCH_PATHS` 指向上述位置
- [ ] 测试：写一个最小 .mm 程序，包含 `libtorrent/session.hpp`，构造 `libtorrent::session`，能编译能跑（不需要真下载，只验证链接成功）
- [ ] CI 工作流加 cache：以 libtorrent 版本号为 key 缓存 build 产物
- [ ] 文档：build 时长（首次约 5-10 分钟）、缓存命中后 < 1 分钟

## 实现提示

- 使用 cmake build：
  ```bash
  cmake -S libtorrent-rasterbar -B build-arm64 \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
        -DBUILD_SHARED_LIBS=OFF
  ```
- libtorrent 2.x 用 cmake；不再需要 boost system 但仍需 boost headers
- macOS 上 boost headers 可用 `brew install boost` 然后 `-DBoost_INCLUDE_DIR=$(brew --prefix boost)/include`，但 CI 上需手动 download
- 推荐 vendor 一份 boost 头文件到 `lib/boost/include`，避免 CI 依赖 homebrew

## 风险

- 首次编译时间长，CI 必须 cache
- libtorrent 2.x 跟 macOS SDK 之间偶有 deprecated 警告，`-Wno-deprecated-declarations`

## Out of scope

- Obj-C++ wrapper（→ Issue 05）
- Swift actor（→ Issue 06）

## Comments

# Issue 02 · Anitomy 桥接（vendored + Obj-C++ target）

Status: ready-for-agent
Sprint: 1 (Schema + Scanner)
Created: 2026-05-29
Updated: 2026-05-29
Related: [ADR-0006](../../../docs/adr/0006-anitomy-bridge.md), PRD §IM-3
BlockedBy: —
Blocks: 03

## 描述

把 Anitomy（C++）vendored 进仓库，建立 `AnitomyBridge` SwiftPM target（Obj-C++），暴露最小 `ANTParser.parse` 接口。布局对齐 `LibtorrentBridge`（ADR-0002）。

## 验收标准

- [ ] `lib/anitomy/` vendored Anitomy 源码（锁定一个 commit/tag，README 记录来源与版本）
- [ ] 新 target `iina-magnet/Sources/AnitomyBridge/`：
  - `AnitomyBridge.mm`：实现 `ANTParser`
  - `include/AnitomyBridge.h`：声明 `+ (nullable NSDictionary<NSString *, id> *)parse:(NSString *)filename;`
  - `include/module.modulemap`：导出给 Swift
- [ ] `iina-magnet/Package.swift`：加入 `AnitomyBridge` target，编译 Anitomy 源码（C++17，`-std=c++17`），设置 header search path
- [ ] `ANTParser.parse` 把 Anitomy `Elements` 转成 `NSDictionary`，key 用原生 element 名（`anime_title`/`episode_number`/`anime_season`/`anime_year`/`video_resolution`/`release_group`/`file_extension`）
- [ ] UTF-8 编码：含中文 / 特殊符号文件名往返不乱码
- [ ] 解析空结果返回 nil（不返回空 dict）
- [ ] target `AnitomyBridgeTests`（或并入现有桥接测试）：
  - `[Nekomoe kissaten][Boku no Hero Academia][01][1080p].mkv` → anime_title/episode_number/release_group/video_resolution 正确
  - 含中文标题样例解析不乱码
  - 垃圾输入返回 nil
- [ ] CI（`iina-magnet-package.yml` / `ci.yml`）能编译该 .mm target

## 实现提示

- Anitomy 是 header + 少量 cpp，无 Boost 依赖，直接随 target 编译，无需独立 build.sh（若上游用 CMake，挑出源文件用 SwiftPM 直编即可）
- Obj-C++ 文件后缀 `.mm`；头文件保持纯 Obj-C（不泄漏 C++ 类型）给 Swift
- `std::wstring` ↔ `NSString`：统一走 UTF-8（`anitomy::string_t` 可能是 `std::wstring`，注意宽窄字符转换）

## Out of scope

- Swift 侧映射与 regex fallback（→ Issue 03）

## Comments

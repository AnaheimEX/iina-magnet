# Issue 03 · iina 主菜单 Hook + Magnet 顶层菜单

Status: ready-to-merge (PR #3 — full iina CI green via workflow_dispatch, awaiting human approval)
Sprint: 0 (Foundation)
Created: 2026-05-26
Updated: 2026-05-26
Related: [ADR-0001](../../../docs/adr/0001-fork-iina-gpl3.md), [ADR-0004](../../../docs/adr/0004-swiftui-independent-windows.md), PRD §IM-9
BlockedBy: 01, 02

## 描述

在 iina 主菜单注入"Magnet"顶层菜单，下挂占位 menu item（Phase 1 末 issue 17 串联），并接入 `Bootstrap.start/.shutdown` 生命周期。

这是本项目对 iina 原代码的**关键 hook 点**，需要严格遵守 hook 约定。

## 验收标准

- [ ] `iina/AppDelegate.swift` 修改：
  - `applicationDidFinishLaunching` 末尾增加：
    ```swift
    // MARK: iina-magnet hook
    IinaMagnetBootstrap.start()
    ```
  - `applicationWillTerminate` 末尾增加：
    ```swift
    // MARK: iina-magnet hook
    IinaMagnetBootstrap.shutdown()
    ```
- [ ] iina 主菜单（`MainMenu.xib` 或代码注册处）增加 "Magnet" 顶层菜单：
  - 位置：在 "Window" 菜单之前
  - 子项：
    - `RSS Manager…` (cmd+shift+R)
    - `BT Manager…` (cmd+shift+B)
    - `Library…` (cmd+shift+L)  *Phase 2 启用，Phase 1 暂禁用 enable=false*
    - 分隔线
    - `Settings…`
    - `Disclaimer…`
  - 所有 menu item action 暂跳到 `IinaMagnetMenuActions` 占位方法
- [ ] `IinaMagnetMenuActions`：
  - Phase 1 内仅 `showRssManager()` / `showBtManager()` / `showSettings()` / `showDisclaimer()` 有实际行为（弹空 SwiftUI 窗口，由后续 issue 填内容）
- [ ] 所有 hook 处加注释 `// MARK: iina-magnet hook`
- [ ] 编写 `docs/iina-hooks.md`：列出本 issue 修改的所有 iina 原文件与原因，作为 sync-workflow 的回归清单
- [ ] CI 通过

## 实现提示

- iina 老版本可能用 xib，新版本可能在 Swift 里 build menu。先 grep "MainMenu" 与 `NSMenu(title:` 找到位置
- `IinaMagnetBootstrap.start()` 在 Phase 0 是空实现（[Issue 01](./01-fork-and-baseline.md) 已建）；后续 issue 在此注册 services
- 别忘了菜单标题字符串走 String Catalog（虽然 Phase 1 暂只填中英文）

## Out of scope

- RSS / BT Manager 窗口实际内容（→ Issue 14, 15）
- Settings 窗口（→ Issue 16）

## Comments

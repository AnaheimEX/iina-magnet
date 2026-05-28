# Issue 20 · Library 菜单启用 + Phase 1 迁移 + 文档与发布

Status: ready-for-agent
Sprint: 5 (待确认 + 验收)
Created: 2026-05-29
Updated: 2026-05-29
Related: PRD §IM-10, US-34/35
BlockedBy: 15, 16, 18, 19
Blocks: —

## 描述

收尾：启用 Phase 1 里灰着的 "Library…" 菜单、打开 LibraryBrowserView；首启动 Phase 2 把 Phase 1 下载完成路径自动注册为 scan root；补用户文档与 retro；打发布 tag。

## 验收标准

- [ ] `Bootstrap.swift`：去掉 Library 菜单项的 `isEnabled = false`；`MagnetMenuActions.showLibrary` 用 `WindowFactory.open(.library, ...)` 打开 `LibraryBrowserView`（替换 Phase 2 placeholder）
- [ ] `WindowFactory` 增 `.library` key
- [ ] 迁移：首次以 Phase 2 启动时，把 `AppSettings.completedDirectory` 自动加入 scan roots（仅一次，标记已迁移）；触发一次后台全量扫描
- [ ] Settings 增 Library 面板：scan roots 增删、TMDB/Bangumi API key、豆瓣开关、元数据缓存 TTL、自动看过阈值
- [ ] Bootstrap 启动 LibraryService + WatchProgressTracker（按依赖顺序，置于 Phase 1 actor 之后）
- [ ] 文档：
  - `README.iina-magnet.md` 增 "媒体库" 段（配 scan root、填 API key、扫描、档案页、三态、待确认队列、改绑）
  - `docs/phase-2/PRD.md` 标记归档
  - `.scratch/phase-2-library/retro.md` 写 Phase 2 回顾
- [ ] ROADMAP.md：Phase 2 状态改"已完成"；打 tag `v0.2.0-phase2`
- [ ] 全套测试通过 + Release 构建干净

## 实现提示

- 迁移标记存 AppSettings（如 `didMigratePhase1Downloads`）
- Library 菜单 keyEquivalent 已是 `cmd+shift+L`（Phase 1 占位时设过），保持
- 启动顺序：TorrentManager → CompletionPipeline → SubscriptionScheduler →（新增）LibraryService → WatchProgressTracker

## Out of scope

- 各功能模块本体（→ 前序 issue）

## Comments

# Issue 15 · LibraryBrowserView 总览（网格/列表 + 搜索）

Status: ready-for-agent
Sprint: 4 (总览 + 三态 + 统计)
Created: 2026-05-29
Updated: 2026-05-29
Related: [ADR-0004](../../../docs/adr/0004-swiftui-independent-windows.md), PRD US-4xx
BlockedBy: 01, 12, 13
Blocks: 16

## 描述

媒体库总览窗口：海报墙（网格）/ 列表两种视图可切换，搜索（中文/原文标题模糊），点击作品打开档案页（Issue 13）。本 issue 做布局 + 切换 + 搜索 + 导航；筛选/统计在 Issue 16。

## 验收标准

- [ ] `iina-magnet/Sources/IinaMagnet/UI/LibraryBrowserView.swift`
- [ ] 网格视图：`LazyVGrid` 海报墙，缩略图懒加载，hover 显示标题；列表视图：标题 / 年份 / 类型 / 集数 / 三态
- [ ] 视图切换 toggle（持久化到 AppSettings）
- [ ] 搜索框：按 titleZh / titleEn / titleJa 模糊匹配，实时过滤
- [ ] 点击作品 → 导航/打开 TitleDetailView（同窗口 NavigationStack 或新窗口，二选一并说明）
- [ ] `@Query` 绑定 Title，排序（默认 updatedAt 倒序）
- [ ] 空库占位（引导去 Settings 配 scan root + 扫描）
- [ ] 1000 作品海报墙滚动不掉帧（PRD §TD-4）

## 实现提示

- 海报缩略图缓存：磁盘缓存 downscale 后的图，避免每次解码原图
- 搜索用 SwiftData `#Predicate` 或内存过滤（量级不大时内存即可）
- `WindowFactory` 加 `.library` key（Issue 20 在菜单接入）

## Out of scope

- 三态 / 类型 / 标签筛选 + 统计块（→ Issue 16）
- 菜单启用（→ Issue 20）

## Comments

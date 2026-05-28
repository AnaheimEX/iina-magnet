# Issue 13 · 档案页 TitleDetailView

Status: ready-for-agent
Sprint: 3 (档案页 UI)
Created: 2026-05-29
Updated: 2026-05-29
Related: [ADR-0004](../../../docs/adr/0004-swiftui-independent-windows.md), PRD US-3xx
BlockedBy: 01, 12
Blocks: 14

## 描述

作品档案页 SwiftUI 视图：backdrop 背景 + 海报 + 标题 / 年份 / 类型 / 评分（TMDB+豆瓣并列）/ 简介 / 演职员；剧集 / 番剧显示按季分组的集数网格，电影显示播放按钮。纯展示 + 选集回调（实际跳播在 Issue 14）。

## 验收标准

- [ ] `iina-magnet/Sources/IinaMagnet/UI/TitleDetailView.swift`
- [ ] 顶部 backdrop（异步加载 + 渐变遮罩），叠海报 + 标题区
- [ ] 元信息：titleZh（主）+ 原标题（次）、releaseYear、kind、tmdbRating / doubanRating 并列、genres/tags chips、overview
- [ ] 演职员横向滚动（头像 + 名字 + 角色）
- [ ] kind==.tv：season picker + 集数网格（每集：集号、标题、看过/进度角标）；kind==.movie：大"播放"按钮
- [ ] 每集 / 电影点击 → 触发 `onPlay(episode:version:)` 回调（占位，Issue 14 接真实播放）
- [ ] 海报 / backdrop / 头像异步加载 + 占位 + 失败兜底
- [ ] `pendingConfirmation` / `unmatched` 作品顶部显示 banner（"匹配不确定，点此确认" → Issue 18 队列）
- [ ] 用 `@Query` / 传入 Title 绑定 SwiftData，进度角标读 WatchProgress
- [ ] 预览（`#Preview`）用内存示例数据，便于无库调试

## 实现提示

- 图片加载用 `AsyncImage` 或轻量缓存；列表海报墙缩略图懒加载（性能见 §TD-4）
- 集数网格用 `LazyVGrid`
- 不在本 issue 里直接调 PlayerCore，保持视图可独立预览

## Out of scope

- 实际跳播 + 版本切换（→ Issue 14）
- 进度回写（→ Issue 17）

## Comments

# Issue 16 · 三态/类型/标签筛选 + 统计块 + 标签编辑

Status: ready-for-agent
Sprint: 4 (总览 + 三态 + 统计)
Created: 2026-05-29
Updated: 2026-05-29
Related: PRD US-4xx
BlockedBy: 15, 17
Blocks: —

## 描述

给总览加筛选与统计：未看/在看/已看三态、类型（tv/movie/unknown）、标签筛选；底部固定统计块（计数 + 点击跳筛选）；作品标签编辑（自动 + 手动）。

## 验收标准

- [ ] 三态筛选（未看/在看/已看）：基于 Title 聚合的 WatchProgress 推导（见下"实现提示"）
- [ ] 类型筛选（tv/movie/unknown）
- [ ] 标签筛选：按 Tag（genre/year/country/releaseGroup/userDefined）多选
- [ ] 筛选可组合（三态 ∧ 类型 ∧ 标签 ∧ 搜索）
- [ ] 底部统计块（固定）：tv / movie / unknown 计数；点击某项 → 应用对应类型筛选（US-28）
- [ ] 标签编辑器：作品上手动加/删 userDefined 标签；自动标签只读展示
- [ ] 单测：
  - 给定一组 Title + WatchProgress，三态分类正确（全看完=已看 / 有进度未全=在看 / 无=未看）
  - 组合筛选结果正确
  - 统计计数正确

## 实现提示

- 三态聚合：一部剧的状态 = f(其所有 Episode 的 WatchProgress)；可在 Title 上缓存一个派生 `aggregateState`（Issue 17 进度回写时更新），UI 直接读，避免每次遍历
- 统计块计数用 SwiftData 聚合查询或内存计数
- 标签筛选 UI：sidebar 或顶部 chips

## Out of scope

- 进度回写本身（→ Issue 17，本 issue 消费其结果）

## Comments

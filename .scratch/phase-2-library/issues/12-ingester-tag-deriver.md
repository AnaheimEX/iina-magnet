# Issue 12 · Ingester + TagDeriver（扫描→元数据→入库 串联）

Status: ready-for-agent
Sprint: 2 (Metadata)
Created: 2026-05-29
Updated: 2026-05-29
Related: [ADR-0005](../../../docs/adr/0005-multi-source-metadata.md), PRD §IM-7
BlockedBy: 04, 09, 10, 11
Blocks: 13, 18, 19

## 描述

把 Scanner（04）→ MetadataService（11）→ SwiftData 串起来。`Ingester` 把 `ScannedFile` + `MetadataResolution` upsert 成 Title/Season/Episode/VersionFile。`TagDeriver`（深模块）从合并元数据 + 版本文件派生标签。

## 验收标准

- [ ] `iina-magnet/Sources/IinaMagnet/Library/Ingester.swift`：
  - upsert 逻辑：按 (tmdbId/bangumiId 或 标题+年份) 找既有 Title，无则建
  - 番剧 / 剧集：建/找 Season + Episode（按 parsed.season/episode），VersionFile 挂到 Episode；电影：挂占位 season0/ep0
  - 同一文件指纹已存在 → 更新 VersionFile（路径 / isMissing），不重复建
  - 写入 matchState / matchScore（来自 MetadataResolution）
  - unmatched：VersionFile 挂到 placeholder Title(kind=.unknown)，保证可见可播
- [ ] `iina-magnet/Sources/IinaMagnet/Metadata/TagDeriver.swift`（深模块，纯函数）：
  - `derive(_ canonical: CanonicalMetadata, _ version: VersionFile) -> [Tag]`
  - 自动标签：genre（来自 genres）、year、country、quality（来自 resolution）、ratingBucket（评分分档）、releaseGroup
  - 去重 + category 正确
- [ ] `LibraryService` 增 `ingest(scannedFiles:)`：对每个文件调 MetadataService.resolve → Ingester.upsert（并发受限，避免 API 突发）
- [ ] 单测：
  - TagDeriver 100% 行覆盖（各 category）
  - Ingester：番剧多集入同一 Title 不同 Episode
  - 同集多版本 → 同 Episode 下多 VersionFile
  - 重复指纹幂等
  - unmatched 入 placeholder
- [ ] 集成测试：假文件树 + 假 MetadataService → fullScan → ingest → 断言 SwiftData 中 Title/Season/Episode/VersionFile 结构

## 实现提示

- upsert 要在同一 ModelContext 事务里，注意 SwiftData actor 隔离（用 ModelActor 或 mainContext 视情况）
- 并发入库限流：用有界 TaskGroup（如同时 ≤4）
- TagDeriver 是纯函数，输入用 CanonicalMetadata 而非 @Model

## Out of scope

- 档案页 / 总览 UI（→ 13/15/16）
- 进度跟踪（→ Issue 17）

## Comments

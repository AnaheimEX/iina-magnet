# Issue 18 · 待确认队列 UI + 手动改绑

Status: ready-for-agent
Sprint: 5 (待确认 + 验收)
Created: 2026-05-29
Updated: 2026-05-29
Related: [ADR-0005](../../../docs/adr/0005-multi-source-metadata.md), PRD US-15/16
BlockedBy: 11, 12, 13
Blocks: —

## 描述

匹配不确定（matchState=.pendingConfirmation / .unmatched）的作品进入"待确认队列"。UI 列出这些作品 + 候选（海报 + 年份辅助），用户选正确条目确认入库；也支持对已确认作品"重新匹配 / 改绑"。

## 验收标准

- [ ] `iina-magnet/Sources/IinaMagnet/UI/PendingConfirmationView.swift`
- [ ] 列出 matchState 非 confirmed 的 Title（及其触发文件名）
- [ ] 每条展示候选列表（来自 MetadataResolution.candidates；含海报、标题、年份、来源 provider）
- [ ] 用户选某候选 → 调 MetadataService 拉该 externalId 的 details → 重新合并 → 更新 Title 字段 + matchState=.confirmed
- [ ] "都不对" → 手动搜索框（输标题 + 年份）重新查 → 选候选
- [ ] 已确认作品的档案页/总览右键"重新匹配"也进同一改绑流程
- [ ] 改绑后旧 placeholder Title（若 unmatched 时建的）合并/清理，VersionFile 迁到正确 Title
- [ ] 单测：
  - 选候选 → Title 字段更新 + state=confirmed
  - 改绑把 VersionFile 从 placeholder 迁到目标 Title
  - 队列只含非 confirmed

## 实现提示

- candidates 需在 Issue 11/12 入库时持久化（或缓存）以便此处展示；若未存则改绑时重查
- 改绑是写操作，注意 SwiftData 关系迁移（重挂 episode/version）

## Out of scope

- 自动匹配逻辑（→ Issue 11）

## Comments

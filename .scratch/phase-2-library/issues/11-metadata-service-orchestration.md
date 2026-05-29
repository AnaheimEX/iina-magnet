# Issue 11 · MetadataService 编排（并发查询 + 超时 + 失败隔离）

Status: partial — 单源 MVP 已合并 develop（MetadataService.resolve：单 provider search → 轻量 title/year 打分选最佳 → details → confirmed/pending/unmatched 分流）。待补：多 provider 并发（async let / TaskGroup）、单源 3s + 总 5s 超时、失败隔离、缓存优先、跨源选 externalId。
Sprint: 2 (Metadata)
Created: 2026-05-29
Updated: 2026-05-29
Related: [ADR-0005](../../../docs/adr/0005-multi-source-metadata.md), PRD §IM-6
BlockedBy: 05, 06, 07, 08, 09, 10
Blocks: 12

## 描述

`actor MetadataService`：给定 `ParsedMedia`，按 Registry 顺序并发查询各 provider → 收集候选 → 用 SimilarityScorer 选最佳 externalId → 拉 details → MetadataMerger 合并 → 返回 `(CanonicalMetadata, score, matchState)`。单 provider 超时 / 失败不阻塞整体。

## 验收标准

- [ ] `iina-magnet/Sources/IinaMagnet/Metadata/MetadataService.swift`（actor）
- [ ] `resolve(_ parsed: ParsedMedia) async -> MetadataResolution`，`MetadataResolution = (canonical: CanonicalMetadata?, candidates: [MetadataCandidate], score: Double, state: MatchState)`
- [ ] 并发：`async let` / TaskGroup 同时打多个 provider 的 search；单 provider 超时 3s，总超时 5s（超时的源跳过）
- [ ] 失败隔离：某 provider throw / 超时 → 记日志、跳过，其余源继续合并
- [ ] 选择：对每源 top 候选用 SimilarityScorer 打分，取全局最高分候选的 externalId 去各源拉 details；合并后产出 canonical
- [ ] 分流（PRD §IM-7）：score≥0.85 → .confirmed；0.65–0.85 → .pendingConfirmation；<0.65 → .unmatched（canonical 可为 nil，candidates 保留供用户选）
- [ ] 缓存优先：details 先查 MetadataCacheStore
- [ ] 单测（注入假 provider，不联网）：
  - 全部成功 → 合并出 canonical，state 按分数
  - 某 provider 超时 → 结果仍产出，不含该源字段
  - 全部失败 → state=.unmatched，canonical=nil，candidates 可能为空
  - 分数边界（0.85 / 0.65）分流正确

## 实现提示

- 总超时用 `withThrowingTaskGroup` + `Task.timeout` 模式（或 `withTimeout` helper）
- 假 provider 用可注入的 `[ProviderID: MetadataProvider]`，便于测延迟 / 抛错
- 不在此 actor 里写 SwiftData——只返回纯结果，入库交 Issue 12

## Out of scope

- upsert / Tag 派生（→ Issue 12）
- 待确认队列 UI（→ Issue 18）

## Comments

# Issue 09 · SimilarityScorer 深模块

Status: ready-for-agent
Sprint: 2 (Metadata)
Created: 2026-05-29
Updated: 2026-05-29
Related: [ADR-0005](../../../docs/adr/0005-multi-source-metadata.md), PRD §IM-7
BlockedBy: 05
Blocks: 11, 12

## 描述

纯函数深模块 `SimilarityScorer.score(parsed:candidate:) -> Double`。把解析出的 `ParsedMedia` 与某个 `MetadataCandidate` 比对，输出 0–1 相似度，用于自动入库 / 待确认分流。

## 验收标准

- [ ] `iina-magnet/Sources/IinaMagnet/Metadata/SimilarityScorer.swift`
- [ ] 算法（ADR-0005）：`标题归一化 Levenshtein(0–1) × 0.6 + 年份匹配 × 0.25 + 季集存在且一致 × 0.15`
  - 标题：双方小写化、去标点空白后算归一化编辑距离（1 - dist/maxLen）
  - 年份：相等满分，±1 年 0.5，缺失或差异大 0
  - 季集：parsed 有 season/episode 且 candidate 类型一致计满分；不适用（电影）该项按标题+年份归一化重分配
- [ ] 输出裁剪到 [0,1]
- [ ] 100% 行覆盖单测：
  - 完全一致 → ≈1.0
  - 标题相近 + 年份对 → 高分
  - 标题对但年份差 3 年 → 中分
  - 完全不相关 → 低分
  - 电影（无季集）权重重分配正确

## 实现提示

- 深模块纯函数，无 IO、无网络
- Levenshtein 用经典 DP；标题先做全角/半角、罗马字大小写归一
- 阈值（0.85/0.65）不在本模块判定，由编排/入库层用（Issue 11/12）

## Out of scope

- 分流决策落地（→ Issue 12）

## Comments

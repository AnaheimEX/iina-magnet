# Issue 10 · MetadataMerger 深模块（100% 覆盖）

Status: ready-for-agent
Sprint: 2 (Metadata)
Created: 2026-05-29
Updated: 2026-05-29
Related: [ADR-0005](../../../docs/adr/0005-multi-source-metadata.md), PRD §IM-2
BlockedBy: 05
Blocks: 12

## 描述

纯函数深模块 `MetadataMerger.merge(_:) -> CanonicalMetadata`。输入各源 `MetadataDetails`，按 ADR-0005 字段优先级表逐字段取"前者非空即用"，合并为一条权威记录。100% 行覆盖。

## 验收标准

- [ ] `iina-magnet/Sources/IinaMagnet/Metadata/MetadataMerger.swift`
- [ ] `merge(_ byProvider: [ProviderID: MetadataDetails]) -> CanonicalMetadata`
- [ ] 字段优先级完全按 ADR-0005 表：
  - titleZh：douban → tmdb-zh → bangumi → tmdb-tw
  - titleEn：tmdb-en → anilist → bangumi-en
  - titleJa：bangumi → anilist → tmdb-ja
  - overview-zh：douban → tmdb-zh；overview-en：tmdb-en → anilist
  - poster：tmdb(最大) → bangumi → anilist；backdrop：tmdb-en → tmdb-zh
  - releaseYear / cast / crew / seasons / episodes / genres / tags / rating 均按表
  - rating：tmdbRating 与 doubanRating **分别保留**（UI 并列显示）
  - tags：tmdb genres + bangumi tags + anilist tags 去重合并
- [ ] 缺某源时跳过该源、用下一优先级；全缺字段为 nil
- [ ] 100% 行覆盖单测：
  - 4 源齐全 → 每字段取对的源
  - 只有 tmdb → 中文字段降级到 tmdb-zh
  - 只有 bangumi（番剧）→ 日文标题优先
  - 豆瓣缺失 → 中文降级 tmdb
  - tags 去重

## 实现提示

- 纯函数、确定性；不接触网络 / SwiftData
- `CanonicalMetadata` 是中间结构（非 @Model），Issue 12 的 Ingester 再 upsert 成 Title
- 字段优先级写成数据驱动（每字段一个 provider 顺序数组），便于校对 ADR 表

## Out of scope

- 相似度（→ Issue 09）、入库（→ Issue 12）

## Comments

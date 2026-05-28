# Issue 07 · BangumiProvider + AnilistProvider

Status: ready-for-agent
Sprint: 2 (Metadata)
Created: 2026-05-29
Updated: 2026-05-29
Related: [ADR-0005](../../../docs/adr/0005-multi-source-metadata.md)
BlockedBy: 05
Blocks: 11

## 描述

实现两个番剧补充源。Bangumi.tv（REST，声优 / 制作委员会 / 中日文标题）与 Anilist（GraphQL，英文剧情 / 英文别名 / 相关作品）。fixture 单测，不联网。

## 验收标准

- [ ] `iina-magnet/Sources/IinaMagnet/Metadata/Providers/BangumiProvider.swift`：
  - `search`：`/v0/search/subjects`（或 `/search/subject`），按番剧名；top-3
  - `details`：`/v0/subjects/{id}` + characters/persons → titleJa/titleZh、overview、声优进 cast、制作进 crew、posterURL、releaseYear、tags（分类项）
  - API key（access token）从 AppSettings 注入（可选；匿名也能查但受限）
- [ ] `iina-magnet/Sources/IinaMagnet/Metadata/Providers/AnilistProvider.swift`：
  - GraphQL `Media(search:type:ANIME)` → top-3 候选；details query 取 titleEn/Native、description(en)、coverImage、相关作品、tags
  - 无需 key（公共 GraphQL endpoint）；遵守 RateLimiter
- [ ] 两者复用 Issue 05 协议与缓存；失败抛错由编排层隔离
- [ ] fixture 单测 `Tests/fixtures/metadata/bangumi/`、`/anilist/`（真实响应，去敏感）：
  - 番剧 search + details 映射（含中日文标题、声优）
  - Anilist GraphQL 响应映射（含英文别名）
  - 错误响应抛预期错误

## 实现提示

- Bangumi 需要 User-Agent（官方要求标明项目）；按其 API 礼仪设置
- Anilist GraphQL：POST query+variables；注意其 rate limit 头
- 声优归到 `cast`，character↔person 关系按 ADR-0005 cast 优先级

## Out of scope

- 豆瓣（→ Issue 08）
- 合并 / 编排（→ 10/11）

## Comments

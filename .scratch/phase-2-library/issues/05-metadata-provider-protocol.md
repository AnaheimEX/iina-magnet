# Issue 05 · MetadataProvider 协议 + Registry + Cache + 限流

Status: ready-for-agent
Sprint: 2 (Metadata)
Created: 2026-05-29
Updated: 2026-05-29
Related: [ADR-0005](../../../docs/adr/0005-multi-source-metadata.md), PRD §IM-6
BlockedBy: 01
Blocks: 06, 07, 08, 10, 11

## 描述

定义元数据子系统的公共契约：`MetadataProvider` 协议、查询/候选/详情数据类型、`ProviderRegistry`、`MetadataCache` 读写封装、单 provider rate limiter。各具体 provider（06/07/08）实现此协议。

## 验收标准

- [ ] `iina-magnet/Sources/IinaMagnet/Metadata/MetadataProvider.swift`：
  ```swift
  enum ProviderID: String, Sendable { case tmdb, bangumi, anilist, douban }
  struct SearchQuery: Sendable { var title: String; var year: Int?; var season: Int?; var episode: Int?; var kindHint: MediaKind; var locale: Locale }
  struct MetadataCandidate: Sendable { var providerId: ProviderID; var externalId: String; var title: String; var year: Int?; var posterURL: URL? }
  struct MetadataDetails: Codable, Sendable { /* ADR-0005 全字段：titleZh/En/Ja, overview, poster/backdrop, cast, crew, seasons[], episodes[], genres, tags, ratings */ }
  protocol MetadataProvider: Sendable {
      var id: ProviderID { get }
      func search(_ query: SearchQuery) async throws -> [MetadataCandidate]   // top-3
      func details(externalId: String, locale: Locale) async throws -> MetadataDetails
  }
  ```
- [ ] `ProviderRegistry`：持有已启用 provider；按 `kindHint` 给出查询顺序（番剧 bangumi+tmdb-tv / 剧集 tmdb-tv / 电影 tmdb-movie / 豆瓣启用则附加）
- [ ] `MetadataCacheStore`：`get(key)` / `put(key,details)`；key=`"<providerId>|<externalId>|<locale>"`；24h TTL；落 `MetadataCache` 表；过期判定 + 手动刷新跳过
- [ ] `RateLimiter`（actor 或 token bucket）：每 provider 独立配额（TMDB ~40req/s，Bangumi 保守 ~1req/s）
- [ ] 单测：
  - Registry 对各 kindHint 返回预期顺序
  - Cache put→get 命中；超 24h miss
  - RateLimiter 在突发请求下不超配额（用假时钟）

## 实现提示

- `MetadataDetails` 必须 `Codable`，因为要进 `MetadataCache.payload`
- API key 不在协议里，provider 构造时由 `AppSettings` 注入；缺 key 的 provider 不进 Registry
- locale 主用 `zh-Hans`，TMDB 英文 backdrop 单独取（ADR-0005）

## Out of scope

- 具体 provider 实现（→ 06/07/08）
- 合并（→ Issue 10）、编排（→ Issue 11）

## Comments

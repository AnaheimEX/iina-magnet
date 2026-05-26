# ADR-0005 · 多源元数据聚合与合并策略

Status: Accepted
Date: 2026-05-26
Related: [ADR-0003](./0003-swiftdata-persistence.md)

## Context

Phase 2 要给媒体库每个作品拉一份"权威元数据"。需求：

- 电影 / 美剧 / 港剧 / 韩剧 / 番剧 都要覆盖
- 中文字段（片名 zh、演员中文名、剧情中文）要质量好
- 番剧专属字段（声优、制作委员会、原作）要拿到
- 海报 / backdrop 要高清
- 失败的源不能阻塞其他源

任何单一源都不够：
- TMDB 中文覆盖少且翻译机械
- 豆瓣无官方 API，需爬虫，反爬激进
- Bangumi.tv 仅日本动画 / Galgame，电视剧空白
- Anilist 主打日漫数据，与 Bangumi 重叠但有英文剧情

## Decision

**多源聚合**。接入 4 个 provider：`tmdb`、`bangumi`、`anilist`、`douban`。结果用 `MetadataMerger` 按字段优先级合并为一条 `Title` 记录。

### 4 个 Provider 角色定位

| Provider | 主用途 | API 状态 |
| --- | --- | --- |
| **TMDB** | 主源。覆盖最广（电影、美/英/韩/港剧）。免费 API key | 官方 API 稳定 |
| **Bangumi.tv** | 番剧补充。声优 / 制作委员会 / 系列关联 | 官方 REST API |
| **Anilist** | 番剧补充。英文剧情、英文别名、相关作品图谱 | GraphQL API |
| **豆瓣** | 中文片名、中文剧情、中文演员名首选 | **无官方 API**，走 web 爬虫，反爬严重；可选关闭 |

### 字段合并优先级表

针对一条作品，每个字段按下面顺序取，前者非空即用：

| 字段 | 优先级（高→低） |
| --- | --- |
| `titleZh` | douban → tmdb-zh-CN → bangumi（中文名）→ tmdb-zh-TW |
| `titleEn` | tmdb-en-US → anilist → bangumi-en |
| `titleJa` | bangumi → anilist → tmdb-ja |
| `overview` (zh) | douban → tmdb-zh-CN → tmdb-zh-TW |
| `overview` (en) | tmdb-en-US → anilist |
| `posterURL` | tmdb（最大尺寸）→ bangumi → anilist |
| `backdropURL` | tmdb-en-US (避免内嵌字幕) → tmdb-zh-CN |
| `releaseYear` | tmdb → bangumi → anilist → douban |
| `cast` | tmdb（含中文名 zh-CN locale）→ bangumi（声优）→ douban |
| `crew` | tmdb → bangumi |
| `seasons[]` | tmdb-tv（剧集）/ bangumi（番剧）/ anilist（次选） |
| `episodes[]` | tmdb-tv / bangumi |
| `genres` | tmdb（标准 genre id）+ bangumi tags 中"分类"项合并去重 |
| `tags` | tmdb genres + bangumi tags + anilist tags + 自动生成的 quality/year/country/ratingBucket |
| `rating` | tmdb 平均 + douban 评分（分别保留，UI 同时显示） |

### 作品类型路由

`Scanner` 把文件名扔给：

1. **Anitomy** 解析。若识别为番剧（anime_title + episode_number 存在）→ Bangumi 主查、TMDB-TV 次查
2. **失败 fallback** → regex 提取 series + season + episode → TMDB-TV 主查
3. **单文件无集数** → TMDB-Movie 主查
4. **无任何匹配** → 进 "unknown" 桶，等用户手动

### 候选确认机制

每个 provider 返回 top-3 候选。聚合后：

- 最高相似度 ≥ 0.85 → 自动入库
- 0.65 ≤ 最高相似度 < 0.85 → 入库但标 `pendingConfirmation`，UI 上有"确认"按钮
- < 0.65 → 进 "待确认队列"，必须用户从候选中选

相似度算法：标题字符串 Levenshtein + 年份匹配加权 + 季集数匹配加权。

### 缓存

每个 `(providerId, externalId, locale)` 24h LRU 缓存到 SwiftData `MetadataCache` 表。手动 "刷新元数据" 跳过缓存。

## Alternatives Considered

### A. 仅 TMDB

简单一致，但中文体验差、番剧细节弱。**用户实际场景（mikanani 番剧主导）会持续踩坑**。放弃。

### B. 用户每个库自选 provider

完全用户可配。优点最灵活；缺点 paradox of choice，初装用户不会选。

放弃 Phase 2，但保留 Phase 3+ 增强空间。

### C. 自建聚合 backend

写一个云端服务统一处理 4 个 provider。架构干净，但需要服务器、密钥、运维。本项目无意维护服务端。

放弃。

## Consequences

### 正面

- 中文用户体验最佳
- 番剧 / 美剧 / 电影都被覆盖
- 单源失败不阻塞（豆瓣爬虫失效时仍能拿到 TMDB 中文）

### 负面与缓解

| 负面 | 缓解 |
| --- | --- |
| 工程复杂：4 个 provider + merger | 抽 `MetadataProvider` 协议，每个 provider 独立模块 |
| 豆瓣爬虫被封 / 反爬变更 | 默认关闭豆瓣；用户主动启用；失败静默 fallback |
| 多源 latency 叠加（串行查询） | 并发查询（`async let` 4 个 provider）+ 总超时 5s |
| API 限流（TMDB 50req/s、Bangumi 偶尔 503） | 单 provider 内 rate limit；缓存优先 |
| 用户看到合并后字段不知道来源 | UI 字段 hover tooltip 显示来源 provider；调试 build 展示 raw JSON |

## 实施约定

- `MetadataProvider` 协议：
  ```swift
  protocol MetadataProvider: Sendable {
      var id: ProviderID { get }
      func search(query: SearchQuery) async throws -> [MetadataCandidate]
      func details(externalId: String, locale: Locale) async throws -> MetadataDetails
  }
  ```
- `MetadataMerger` 是**深模块**，纯函数式：input = `[ProviderID: MetadataDetails]`，output = `CanonicalMetadata`。必须有 100% 行覆盖的单测
- API key 通过 `Settings` 用户配置（TMDB/Bangumi 必需）；不内置任何 key
- 豆瓣爬虫规则放独立文件 `Providers/Douban/Scraper.swift`，遇到反爬变更可热替换
- 每个 provider 必有 fixture-based 单测（不依赖网络）

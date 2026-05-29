# SwiftData Schema

> 所有 `@Model` 的权威清单。schema 演进时**增量更新**本文件。容器与迁移策略见 [ADR-0003](./adr/0003-swiftdata-persistence.md)；全部 model 在 `PersistenceController.swift` 的 `Schema([...])` 注册。
>
> 部署目标 macOS 14。`#Index` / `#Unique` 宏需 macOS 15，本项目暂不可用——硬约束用 `@Attribute(.unique)`，其余筛选维度走内存过滤 / `#Predicate`。复合索引待最低系统升到 macOS 15 再加。

## Phase 1 · BT / RSS（已合并）

| Model | 关键字段 | 约束 / 关系 |
| --- | --- | --- |
| `DisclaimerAcceptance` | version, acceptedAt | — |
| `TorrentTask` | infoHash(unique), savePath, statusRaw, progress | — |
| `SubscriptionSource` | url(unique), displayName, pollIntervalSeconds, cookieHeader, customHeaders, enabled | `rules` 1-N cascade → SubscriptionRule |
| `SubscriptionRule` | name, include[], exclude[], regex?, caseSensitive, enabled, hitCount | inverse → source |
| `FeedItem` | guid(unique), title, enclosureURL, publishedAt, matched | source / matchedRule 关系 |

## Phase 2 · 媒体库（Issue 01）

> 枚举存 `*Raw: Int` + 计算属性（沿用 TorrentTaskStatus）。`MediaKind` / `MatchState` / `TagCategory` / `ProgressState` 见 `Library/Models/LibraryEnums.swift`。

| Model | 关键字段 | 约束 / 关系 |
| --- | --- | --- |
| `Title` | tmdbId?/bangumiId?/anilistId?/doubanId?, titleZh/En/Ja?, kindRaw, overview?, posterURL?/backdropURL?, releaseYear?, bangumiRating?/tmdbRating?/doubanRating?, runtimeMinutes?(电影时长), matchStateRaw, matchScore, aggregateStateRaw | `seasons` 1-N cascade；`tags` N-N（删 Title 不删 Tag） |
| `Season` | number | inverse → title；`episodes` 1-N cascade |
| `Episode` | number, seasonNumber(冗余), title?(zh), titleOriginal?(ja/en), airDate?, overview?, thumbnailURL? | inverse → season；`versions` 1-N cascade |
| `VersionFile` | fileURL, bookmark?, fileSizeBytes, fileFingerprint(unique), resolution?, releaseGroup?, languages[], isMissing | inverse → episode |
| `Tag` | name, categoryRaw | `titles` N-N（inverse of Title.tags） |
| `Credit` | actorName(声优), characterName?(角色), order | inverse → title；Title.credits 1-N cascade（Bangumi characters） |
| `WatchProgress` | seasonNumber?, episodeNumber?, lastPositionSec, durationSec, stateRaw, updatedAt | `title` 关系（不存 PersistentIdentifier）；键 (title, season, episode) 跨版本共享 |
| `MetadataCache` | cacheKey(unique)=`"<provider>\|<externalId>\|<locale>"`, payload(Data), fetchedAt | 24h TTL（Issue 05 写读） |

### 设计要点

- **进度跨版本共享**：`WatchProgress` 键为 `(title, seasonNumber, episodeNumber)`，不绑 `VersionFile`，所以一集换清晰度版本仍显示同一进度（PRD US-20）。
- **不存 `PersistentIdentifier`**：SwiftData 不接受裸 `PersistentIdentifier` 作存储属性（同 `FeedItem.source` 教训），故 `WatchProgress.title` 用 `@Relationship`。
- **电影占位**：电影用 `Season(number: 0)` + `Episode(number: 0)` 挂 `VersionFile`，UI 按 `kind == .movie` 隐藏集数网格。
- **`aggregateStateRaw`**：Title 上缓存的派生三态，由 WatchProgressTracker（Issue 17）更新、三态筛选（Issue 16）消费，避免每次遍历全部 Episode。
- **唯一约束即 upsert**：`@Attribute(.unique)`（fileFingerprint / cacheKey / url / infoHash / guid）冲突时 SwiftData 以该键 upsert，不产生重复行——扫描器（Issue 04）据此幂等。

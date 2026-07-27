# 当前 SwiftData Schema

> 所有 `@Model` 的当前权威清单。全部 model 在
> `iina-magnet/Sources/IinaMagnet/Persistence/PersistenceController.swift` 的
> `Schema([...])` 注册；修改代码时同步更新本文件。
>
> 部署目标 macOS 14。`#Index` / `#Unique` 宏需 macOS 15，本项目暂不可用——硬约束用 `@Attribute(.unique)`，其余筛选维度走内存过滤 / `#Predicate`。复合索引待最低系统升到 macOS 15 再加。

## 当前模型

| Model | 关键字段 | 约束 / 关系 |
| --- | --- | --- |
| `DisclaimerAcceptance` | version, acceptedAt | — |
| `Title` | tmdbId?/bangumiId?/anilistId?/doubanId?, titleZh/En/Ja?, kindRaw, overview?, posterURL?/backdropURL?, releaseYear?, bangumiRating?/tmdbRating?/doubanRating?, runtimeMinutes?(电影时长), matchStateRaw, matchScore, aggregateStateRaw | `seasons` 1-N cascade；`tags` N-N（删 Title 不删 Tag） |
| `Season` | number | inverse → title；`episodes` 1-N cascade |
| `Episode` | number, seasonNumber(冗余), title?(zh), titleOriginal?(ja/en), airDate?, overview?, thumbnailURL? | inverse → season；`versions` 1-N cascade |
| `VersionFile` | fileURL, bookmark?, fileSizeBytes, fileFingerprint(unique), resolution?, releaseGroup?, languages[], isMissing | inverse → episode |
| `Tag` | name, categoryRaw | `titles` N-N（inverse of Title.tags） |
| `Credit` | actorName(声优), characterName?(角色), order | inverse → title；Title.credits 1-N cascade（Bangumi characters） |
| `WatchProgress` | seasonNumber?, episodeNumber?, lastPositionSec, durationSec, stateRaw, updatedAt | `title` 关系（不存 PersistentIdentifier）；键 (title, season, episode) 跨版本共享 |
| `MetadataCache` | cacheKey(unique)=`"<provider>\|<externalId>\|<locale>"`, payload(Data), fetchedAt | 24h TTL |

PikPak 与 Mikan 不新增 SwiftData model：认证状态分别保存在 Keychain/WebKit，网盘文件实时
读取、不写入媒体库数据库。

枚举使用 `*Raw: Int` 存储并通过计算属性暴露；定义见
`Library/Models/LibraryEnums.swift`。

### 设计要点

- **进度跨版本共享**：`WatchProgress` 键为 `(title, seasonNumber, episodeNumber)`，不绑 `VersionFile`，所以一集换清晰度版本仍显示同一进度。
- **不存 `PersistentIdentifier`**：SwiftData 不接受裸 `PersistentIdentifier` 作存储属性，故 `WatchProgress.title` 用 `@Relationship`。
- **电影占位**：电影用 `Season(number: 0)` + `Episode(number: 0)` 挂 `VersionFile`，UI 按 `kind == .movie` 隐藏集数网格。
- **`aggregateStateRaw`**：Title 上缓存的派生三态，由 WatchProgressTracker 更新、三态筛选消费，避免每次遍历全部 Episode。
- **唯一约束即 upsert**：`@Attribute(.unique)`（`fileFingerprint` / `cacheKey`）冲突时 SwiftData 以该键 upsert，不产生重复行，扫描器据此幂等。

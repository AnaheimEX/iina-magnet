# Issue 01 · 媒体库 SwiftData schema

Status: completed (implemented on branch phase2/01-library-schema)
Sprint: 1 (Schema + Scanner)
Created: 2026-05-29
Updated: 2026-05-29
Related: [ADR-0003](../../../docs/adr/0003-swiftdata-persistence.md), PRD §IM-4
BlockedBy: —
Blocks: 04, 11, 12, 13, 15, 16, 17

## 描述

定义 Phase 2 的 SwiftData `@Model`：`Title` / `Season` / `Episode` / `VersionFile` / `Tag` / `WatchProgress` / `MetadataCache`，以及配套枚举。注册进 `PersistenceController`。配 CRUD 单测。

## 验收标准

- [ ] 文件 `iina-magnet/Sources/IinaMagnet/Library/Models/` 下：
  - `Title.swift`、`Season.swift`、`Episode.swift`、`VersionFile.swift`、`Tag.swift`、`WatchProgress.swift`、`MetadataCache.swift`
  - `LibraryEnums.swift`：`MediaKind`（.tv/.movie/.unknown）、`MatchState`（.confirmed/.pendingConfirmation/.unmatched）、`TagCategory`（.genre/.year/.country/.ratingBucket/.quality/.releaseGroup/.userDefined）、`ProgressState`（.unseen/.inProgress/.completed）
- [ ] 字段完全按 PRD §IM-4（含 `matchState`/`matchScore`/`fileFingerprint`/`bookmark`/`isMissing`）
- [ ] 关系：`Title.seasons`、`Season.episodes`、`Episode.versions` 均 `@Relationship(deleteRule: .cascade)` 且配 inverse；`Title.tags` 多对多（删 Title 不删共享 Tag）
- [ ] 索引：`VersionFile.fileFingerprint` 唯一；`Title.kind`、`WatchProgress`(titleId+season+episode) 复合
- [ ] `MetadataCache.cacheKey` 唯一索引
- [ ] `PersistenceController.modelTypes` 追加全部新 model；确认与 Phase 1 模型共存、lightweight migration 通过（旧库能打开）
- [ ] 单测：
  - 建 Title→Season→Episode→VersionFile 链，查询验证级联
  - 删 Title 级联删 Season/Episode/VersionFile，但不删 Tag
  - VersionFile.fileFingerprint 重复插入被唯一约束拒绝
  - WatchProgress 以 (titleId, season, episode) 查询命中
- [ ] 文档：新建 `docs/schema.md` 或在其追加 Phase 2 表（schema 演进增量更新）

## 实现提示

- `fileURL` 存路径，另存安全作用域 bookmark 到 `bookmark: Data?`（沙箱外路径需要；当前未启沙箱也先存，向前兼容）
- `WatchProgress` **不引用 VersionFile**，键为 (titleId, season, episode)，实现 US-20 跨版本共享进度
- 电影：用占位 `Season(number:0)` + `Episode(number:0)` 挂 VersionFile，UI 层据 `kind==.movie` 隐藏集数网格
- `MetadataCache.payload` 存 `Codable` 编码的 `MetadataDetails`（Issue 05 定义；本 issue 先用 `Data` 占位）

## Out of scope

- 扫描 / 入库逻辑（→ Issue 04, 12）
- 元数据类型 MetadataDetails 的具体字段（→ Issue 05）

## Comments

### 2026-05-29 claude
实现完成。要点 / 与 issue 的偏差：
- 枚举存 `*Raw: Int` + 计算属性（沿用 `TorrentTaskStatus` 约定），非直接存 Codable enum。
- 复合索引（`Title.kind`、`WatchProgress` 三键）**未加**：部署目标 macOS 14，`#Index` 宏需 macOS 15。唯一约束用 `@Attribute(.unique)`（fileFingerprint / cacheKey），其余走内存过滤 / `#Predicate`。已在 `docs/schema.md` 注明，待最低系统升 15 再补。
- `WatchProgress` 不存 `PersistentIdentifier`（SwiftData 拒绝裸 PersistentIdentifier，同 FeedItem 教训），改用 `@Relationship var title: Title?` + `seasonNumber/episodeNumber`，仍满足跨版本共享进度。
- 新增 `Title.aggregateStateRaw`（PRD §IM-4 未列）：缓存派生三态，供 Issue 16/17 复用，避免后续迁移。
- 测试用 `ModelContext(container)` 而非 `.mainContext`：本机 CLI swift-testing 工具链（macOS 26 beta）在 `.mainContext` save 处 trap，与 schema 无关；`ModelContext` 是 Phase 1 既有的逐用例隔离写法。
- 全套 58 tests / 11 suites 通过（新增 7 个 LibrarySchema 用例）。

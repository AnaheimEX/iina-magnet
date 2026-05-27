# Issue 10 · RSS 数据模型 (SwiftData schema)

Status: completed (merged to develop)
Sprint: 3 (RSS)
Created: 2026-05-26
Updated: 2026-05-26
Related: [ADR-0003](../../../docs/adr/0003-swiftdata-persistence.md), PRD §IM-4
BlockedBy: 01
Blocks: 11, 12, 13

## 描述

定义 `SubscriptionSource` / `SubscriptionRule` / `FeedItem` 三个 SwiftData `@Model`，加入 `PersistenceController.schema`。配套基本的 CRUD 单元测试。

## 验收标准

- [ ] 文件：
  - `iina-magnet/Sources/IinaMagnet/Persistence/Models/SubscriptionSource.swift`
  - `iina-magnet/Sources/IinaMagnet/Persistence/Models/SubscriptionRule.swift`
  - `iina-magnet/Sources/IinaMagnet/Persistence/Models/FeedItem.swift`
- [ ] schema 完全按 PRD §IM-4：
  - `SubscriptionSource`：url、displayName、pollInterval、cookieHeader、customHeaders、enabled、rules、lastPolledAt、lastPollResult
  - `SubscriptionRule`：name、include、exclude、regex、caseSensitive、enabled、hitCount
  - `FeedItem`：guid (unique), title, enclosureURL, publishedAt, sourceId, matched, matchedRuleId, firstSeenAt
- [ ] `PollResult` enum：`.success(itemCount: Int)` / `.error(message: String)`
- [ ] `PersistenceController.modelTypes` 加入这三个 model
- [ ] 索引：
  - `FeedItem.guid` 唯一索引
  - `FeedItem.sourceId` + `publishedAt` 复合索引（用于按源按时间倒序展示）
- [ ] 单元测试：
  - CRUD 单 SubscriptionSource → 增加 rules → 查询验证
  - 插入 100 个 FeedItem → guid 重复时不插入第二条
  - 删除 SubscriptionSource 级联清理其 rules（`@Relationship(deleteRule: .cascade)`）
  - FeedItem 不被级联删除（保留命中历史）
- [ ] 文档：`docs/schema.md` 第一节加入这三张表（schema 演进时增量更新）

## 实现提示

- `customHeaders: [String: String]` 在 SwiftData 用 `@Attribute` Codable 存
- `rules` 用 `@Relationship` 一对多，不要在 SubscriptionRule 也存 `sourceId`（用 inverse 自动维护）
- `regex` 字段 nil = 不用正则；空字符串 = 视为 nil（输入时归一化）
- `pollInterval` 单位：秒。默认 1800（30min）

## Out of scope

- 实际 RSS 拉取（→ Issue 12）
- Rule engine（→ Issue 11）
- UI（→ Issue 14）

## Comments

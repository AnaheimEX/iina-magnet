# Issue 11 · RssRuleEngine 深模块

Status: completed (merged to develop)
Sprint: 3 (RSS)
Created: 2026-05-26
Updated: 2026-05-26
Related: PRD §IM-5, US-9..16
BlockedBy: 10
Blocks: 12, 14

## 描述

把 Feed 条目数组与规则数组打成 Match 数组。**纯函数式深模块**，100% 单测覆盖。

## 验收标准

- [ ] `iina-magnet/Sources/IinaMagnet/Rss/RssRuleEngine.swift`
- [ ] API：
  ```swift
  struct EngineRule: Sendable, Equatable {
      let id: PersistentIdentifier
      let name: String
      let include: [String]
      let exclude: [String]
      let regex: String?    // nil = 不用正则
      let caseSensitive: Bool
      let enabled: Bool
  }

  struct EngineFeedItem: Sendable, Equatable {
      let guid: String
      let title: String
  }

  struct EngineMatch: Sendable, Equatable {
      let itemGuid: String
      let ruleId: PersistentIdentifier
      let ruleName: String
  }

  struct RssRuleEngine {
      static func evaluate(items: [EngineFeedItem], rules: [EngineRule]) -> [EngineMatch]
  }
  ```
- [ ] 算法（PRD §IM-5）：
  ```
  for item in items:
      for rule in rules where rule.enabled:
          if rule.regex != nil:
              match = regex(rule.regex).firstMatch(item.title) != nil
          else:
              hay = rule.caseSensitive ? item.title : item.title.lowercased()
              inc = rule.caseSensitive ? rule.include : rule.include.map(.lowercased)
              exc = rule.caseSensitive ? rule.exclude : rule.exclude.map(.lowercased)
              match = (inc.isEmpty || inc.allSatisfy { hay.contains($0) })
                      && !exc.contains(where: { hay.contains($0) })
          if match:
              produce EngineMatch(item.guid, rule.id, rule.name)
              break  # 一个 item 只走最早的 enabled 规则
  ```
- [ ] 不可变 / 无副作用 / 无 IO
- [ ] regex 编译错误：返回不命中（不抛异常，UI 端在写入时校验）
- [ ] 单元测试 ≥ 100% 行覆盖：
  - 空 items / 空 rules
  - 仅 include 命中
  - 仅 exclude 否决
  - include + exclude 共同作用
  - caseSensitive=false 大小写无关
  - caseSensitive=true 严格匹配
  - regex 命中 / 不命中
  - regex 无效 → 不抛错，不命中
  - 多规则同时命中 → 仅第一条 enabled 出现在结果
  - disabled 规则跳过
  - 性能基准：1000 items × 50 rules < 50ms（单线程；XCTest measure）

## 实现提示

- 用 `NSRegularExpression` 或 Swift `Regex`（macOS 13+）；优先 Swift `Regex` 类型安全
- `Match` 类型不引用 SwiftData `PersistentIdentifier` 之外的 model（保持 actor 边界清晰）
- 调用方（Scheduler）转换 `SubscriptionRule` → `EngineRule`，`FeedItem` → `EngineFeedItem`

## Out of scope

- 持久化（→ Issue 10 已经做）
- 调度（→ Issue 13）

## Comments

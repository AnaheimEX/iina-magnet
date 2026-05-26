# Issue 13 · SubscriptionScheduler actor

Status: ready-for-agent
Sprint: 3 (RSS)
Created: 2026-05-26
Updated: 2026-05-26
Related: PRD US-1xx, US-8xx
BlockedBy: 11, 12
Blocks: 17

## 描述

把 `Fetcher` / `Parser` / `RuleEngine` / `TorrentManager.addMagnet` 串成调度链路：按 `pollInterval` 轮询订阅源 → 拉取 → 解析 → 去重 → 规则匹配 → 入下载队列。

actor 化，外部测试用假时钟。

## 验收标准

- [ ] `SubscriptionScheduler` actor：
  ```swift
  actor SubscriptionScheduler {
      init(persistence: PersistenceController, fetcher: any Fetcher, torrent: TorrentManager, clock: any Clock<Duration>)
      func start() async   // 启动调度（仅启动一次）
      func stop() async
      func pollNow(sourceId: PersistentIdentifier) async  // 用户手动触发
  }
  ```
- [ ] 调度逻辑：
  - `start` 后，遍历 `SubscriptionSource where enabled = true`
  - 为每个 source 启动一个 child Task：
    ```
    while not cancelled:
        nextRun = source.lastPolledAt ?? Date.distantPast + source.pollInterval
        sleep until nextRun
        try { pollOnce(source) }
        catch { source.lastPollResult = .error(msg) }
        update source.lastPolledAt
    ```
- [ ] `pollOnce(source)`：
  - `Fetcher.fetch` → raw data
  - `FeedParser.parse` → `[ParsedFeedItem]`
  - 去重：query `FeedItem` where guid in newGuids → 过滤已存在
  - 写入新 `FeedItem`
  - 取 `source.rules`，转 `EngineRule[]`；`EngineFeedItem` 构造；`RssRuleEngine.evaluate`
  - 对每个 Match：标记 FeedItem.matched + matchedRuleId + rule.hitCount++
  - 对每个 Match：调 `TorrentManager.addMagnet(enclosureURL, savePath: cacheDir/<infoHash>/)`
  - source.lastPollResult = .success(itemCount)
- [ ] 用户手动 `pollNow(sourceId)` 立即触发一次（跨 actor 安全）
- [ ] Burst 避免：源的实际 nextRun 在 ±10% 抖动范围内
- [ ] `Clock<Duration>` 协议化（`ContinuousClock` 生产；测试用 `MockClock`）
- [ ] 单元测试：
  - 假时钟前进 30min → 一个 1800s 源触发一次
  - 多源不会同 tick 触发（抖动验证）
  - source 改 disabled → child task 取消
  - 添加 source → 启动新 child task
  - poll 异常不影响其它源
- [ ] 集成测试：
  - 启动 scheduler + 假 fetcher 返回固定 XML + 假 torrent manager
  - 命中规则 → addMagnet 被调用 1 次 + FeedItem.matched 写入

## 实现提示

- Swift `Clock<Duration>`（macOS 13+）做依赖注入
- 假时钟用 `Mock` 类型，`sleep` 转 `await mockClock.advance(...)`
- child task 用 `TaskGroup`，每个 source 一个 `addTask`
- pollNow 通过专用 actor inbox（async channel 或 AsyncStream）触发对应 child

## Out of scope

- UI（→ Issue 14）

## Comments

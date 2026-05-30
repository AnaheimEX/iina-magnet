# Issue 17 · 播放进度回写 + 三态驱动（IinaBridge hook）

Status: completed (merged to develop)
Sprint: 4 (总览 + 三态 + 统计)
Created: 2026-05-29
Updated: 2026-05-29
Related: PRD §IM-9, US-5xx
BlockedBy: 01, 14
Blocks: 16

## 描述

扩展 Phase 1 `IinaBridge`，让 iina 播放位置变化 / 文件结束时回调；`WatchProgressTracker`（actor）把回调归一到 (title, season, episode) 写 WatchProgress，≥90% 标已看，中途退出记位置并置在看，并更新 Title 的派生聚合态供三态用。

## 验收标准

- [ ] `IinaBridge` 协议（Phase 1 `Streaming/IinaBridge.swift`）扩展：
  `func observePlaybackProgress(_ handler: @escaping (URL, _ positionSec: Double, _ durationSec: Double, _ ended: Bool) -> Void)`
- [ ] iina 侧 hook `iina/IinaMagnetBridge.swift`（**复用 Phase 1 同一文件**，加 `// MARK: iina-magnet hook`）：监听 `PlayerCore.active` 的 time-pos 变化与 EOF，回调上报
- [ ] `iina-magnet/Sources/IinaMagnet/Library/WatchProgressTracker.swift`（actor）：
  - 收到回调 → 用 url 反查 VersionFile → 取 (titleId, season, episode) → upsert WatchProgress
  - position/duration ≥ 0.9 或 ended → state=.completed；0<比例<0.9 → .inProgress + lastPositionSec
  - 防抖写入（如每 5s 或位置跳变 > 阈值才落库）
- [ ] 更新 Title 派生聚合态（供 Issue 16 三态）：该 Title 全 Episode completed → 已看；有 inProgress/部分 completed → 在看；无 → 未看
- [ ] Bootstrap 启动 WatchProgressTracker 并向 IinaBridge 注册回调
- [ ] 单测（注入假回调序列，不依赖 iina）：
  - 播放到 95% → completed
  - 播放到 40% 退出 → inProgress + 记位置
  - 一部剧最后一集 completed → Title 聚合态变已看
  - 跨版本：同集不同 url 都映射到同一 (title,season,episode)

## 实现提示

- url→VersionFile 反查：用 fileFingerprint 或 path 索引
- 防抖避免高频写 SwiftData
- 注意 actor 与 iina 主线程回调的跨界（回调里只投递，actor 内处理）

## Out of scope

- 三态筛选 UI（→ Issue 16，消费聚合态）

## Comments

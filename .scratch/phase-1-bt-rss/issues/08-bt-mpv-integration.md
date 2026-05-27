# Issue 08 · BT-mpv 集成（PlayerCore hook + StreamPlanner 调度）

Status: completed (merged to develop)
Sprint: 2 (边看边播)
Created: 2026-05-26
Updated: 2026-05-26
Related: [ADR-0002](../../../docs/adr/0002-libtorrent-inproc.md), PRD US-27..32
BlockedBy: 06, 07

## 描述

把 `StreamPlanner` 与 `TorrentManager` 接到 iina `PlayerCore`：用户在 BT Manager 双击未完成任务 → 调用 `PlayerCore.openURL(sparseFile)` → `StreamCoordinator` 订阅播放位置变化 → 反馈给 `TorrentManager.setPieceDeadline`。

## 验收标准

- [ ] `StreamCoordinator` actor，每个流式播放任务一个实例：
  - 初始化：`(infoHash, videoFileIndex, playerCore)`
  - 启动后周期性（每 1s 或 mpv 报告 time-pos 事件时）调 `StreamPlanner.plan(...)` → `TorrentManager.setPieceDeadline(...)`
  - mpv seek 时立即重算
  - 播放停止 / mpv 关闭 → 释放 deadline（设为高值），cancel coordinator
- [ ] PlayerCore hook（最小化）：
  - iina 原 `PlayerCore` 加一个 `// MARK: iina-magnet hook` 入口：
    ```swift
    var magnetStreamCoordinator: (any StreamCoordinatorProtocol)? = nil
    ```
  - `protocol StreamCoordinatorProtocol` 定义在 IinaMagnet，PlayerCore 通过弱引用持有
  - PlayerCore 时间变化 / seek 时通知 coordinator
- [ ] 用户在 BT Manager（占位 UI 即可）双击任务 → `MagnetRouter.playStreaming(infoHash, fileIndex)`：
  - 找到 sparse file URL
  - 创建 `StreamCoordinator`
  - 调 `PlayerCore.openURL`
  - 把 coordinator 设到 PlayerCore.magnetStreamCoordinator
- [ ] mpv 缓冲不足时不退出（`--demuxer-readahead-secs` 在 iina 已有；validate 不需新设置）
- [ ] 集成测试：
  - 用一个开源大文件 fixture（Big Buck Bunny torrent 或本地模拟），下载到 10% 时启动播放
  - 验证 mpv 能播 5-10 秒
  - 验证 piece deadline 被设置到 urgent 区间
  - seek 到文件 50% 处 → urgent piece 重算 → libtorrent 优先级变化

## 实现提示

- iina `PlayerCore` 是大类，**不要**移到 IinaMagnet；仅加 1 个 property + 2 处通知 hook（time-pos + seek）
- StreamCoordinator 持有 PlayerCore 弱引用避免循环
- 多 torrent 同时流式播放：每个 PlayerCore 各一个 coordinator；TorrentManager 串行化
- 单 torrent 多文件场景（合集）：先实现 "用户从 torrent 多文件列表选一个" 的 router 入口；播放列表化在 Issue 15

## Out of scope

- Subtitle 提取（→ Issue 09）
- BT Manager UI（→ Issue 15）

## Comments

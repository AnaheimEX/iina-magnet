# Issue 06 · TorrentManager actor + alert pumping

Status: completed (merged to develop)
Sprint: 1 (libtorrent 桥接)
Created: 2026-05-26
Updated: 2026-05-26
Related: [ADR-0002](../../../docs/adr/0002-libtorrent-inproc.md), PRD US-3xx
BlockedBy: 05
Blocks: 07, 17

## 描述

Swift `TorrentManager` actor 包装 `LMSession`，对外提供 async / Observable API；负责 alert 轮询（50ms 间隔）并把事件转 `AsyncStream`。

## 验收标准

- [ ] `TorrentManager` 是 `actor`，作为单例 `TorrentManager.shared`
- [ ] API：
  ```swift
  @MainActor
  @Observable final class TorrentTaskList { var tasks: [TorrentTask] = [] }

  actor TorrentManager {
      static let shared: TorrentManager
      var events: AsyncStream<TorrentEvent> { get }
      func addMagnet(_ uri: String, savePath: URL) async throws -> InfoHash
      func addTorrentFile(_ data: Data, savePath: URL) async throws -> InfoHash
      func pause(_ infoHash: InfoHash) async
      func resume(_ infoHash: InfoHash) async
      func remove(_ infoHash: InfoHash, deleteFiles: Bool) async
      func setSequentialDownload(_ infoHash: InfoHash, enabled: Bool) async
      func setPieceDeadline(_ infoHash: InfoHash, piece: Int, deadlineMs: Int) async
      func status(of infoHash: InfoHash) async -> TorrentStatus?
      func allStatuses() async -> [TorrentStatus]
  }
  ```
- [ ] `InfoHash` 类型：`struct InfoHash: Hashable, Sendable { let hex: String }`
- [ ] `TorrentEvent` enum：`.metadataReceived(InfoHash)`, `.pieceFinished(InfoHash, Int)`, `.fileCompleted(InfoHash, fileIndex: Int)`, `.torrentFinished(InfoHash)`, `.error(InfoHash, message: String)`
- [ ] `TorrentTask` SwiftData `@Model`：infoHash (unique), savePath, displayName, status, progress, addedAt（schema 加入 PersistenceController）
- [ ] Alert pumping：
  - 私有 `Timer` (50ms) 调 `session.pumpAlerts()`
  - alert 转 `TorrentEvent` 推到 `AsyncStream`
  - 同时更新 SwiftData `TorrentTask.status` / `progress`
- [ ] 应用生命周期：
  - 启动时（`IinaMagnetBootstrap.start`）创建 `LMSession` 并恢复未完成任务（从 SwiftData 读，调 `addTorrentFile` 或 `addMagnet` resume）
  - 退出时（`shutdown`）pause 所有 + 保存 resume data
- [ ] 单元测试：
  - 用 mock `LMSession` 验证 actor 串行化
  - `events` AsyncStream 被多消费者订阅时不阻塞
- [ ] 集成测试：
  - 用本地 .torrent fixture + 本地 tracker（已下载文件做 seed peer）
  - addTorrentFile → 等待 .torrentFinished 事件 → 验证文件 hash 正确
  - 删除任务 → 验证文件被删

## 实现提示

- `LMSession` 不是 Sendable，全部访问必须在 actor 内
- `AsyncStream` 用 `Continuation` 模式；多消费者用 broadcast pattern 或保留单消费者（与 UI 配合）
- alert pumping Timer 在 actor 内安排，避免跨 thread
- 启动时 resume：每个未完成 task 重新 add 时，libtorrent 会从已有 sparse 文件继续

## Out of scope

- StreamPlanner 算法（→ Issue 07）
- Subtitle 提取（→ Issue 09）
- UI（→ Issue 15）

## Comments

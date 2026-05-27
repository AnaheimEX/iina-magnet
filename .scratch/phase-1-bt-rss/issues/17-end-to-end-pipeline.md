# Issue 17 · 端到端串联：Match → 下载 → 完成 → 移动 → 字幕

Status: completed (merged to develop)
Sprint: 4 (UI / 集成)
Created: 2026-05-26
Updated: 2026-05-26
Related: PRD US-25, US-26, US-33..37
BlockedBy: 06, 09, 13, 16

## 描述

`SubscriptionScheduler` 命中规则 → `TorrentManager.addMagnet` 已在 Issue 13 接通。本 issue 处理"下载完成之后"的流程：移动到下载完成路径 + 字幕外挂提取 + 通知 UI。

## 验收标准

- [ ] `CompletionPipeline` actor（监听 `TorrentManager.events`）：
  - 收到 `.torrentFinished(infoHash)`：
    - 读 `AppSettings.completedPath`
    - 若 `autoMove == true`：
      - 计算目标目录：`<completedPath>/<task.displayName>/`
      - 用 `FileManager.moveItem` 移动整个 torrent 目录（cache → completedPath）
      - 移动失败（跨卷 / 磁盘满）→ 错误 banner，原 cache 保留
    - 调 `SubtitleExtractor.plan` 与 `.execute` 在目标目录（或 autoMove=false 时在原位）
    - 移动成功后清理 cache 中该 torrent 的目录
    - 更新 `TorrentTask.savePath` 为新位置
    - 发系统通知（macOS UserNotifications）："X 下载完成"
- [ ] 移动期间 BT Manager 显示 "归档中…" 状态
- [ ] 磁盘空间预警：移动前检查目标卷空间 < 阈值 → 弹 alert
- [ ] 集成测试：
  - 启动假 torrent（已下完的本地 fixture，构造 `.torrentFinished` 事件）
  - autoMove=true → 文件出现在 completedPath，cache 被清
  - autoMove=false → 文件留 cache，无错误
  - 字幕 fixture（含 .ass 文件）→ 移动后 sidecar 字幕生成
- [ ] 错误处理：
  - 目标已存在同名目录 → 加 `_<N>` 后缀，不覆盖
  - 移动权限不足 → banner + 日志

## 实现提示

- `CompletionPipeline` 在 `IinaMagnetBootstrap.start` 启动
- 用 `for await event in TorrentManager.shared.events` 监听
- 移动整个目录：`FileManager.moveItem(at:to:)`；跨卷会自动 copy+delete，慢但正确

## Out of scope

- 入库（Phase 2 Scanner 负责）

## Comments

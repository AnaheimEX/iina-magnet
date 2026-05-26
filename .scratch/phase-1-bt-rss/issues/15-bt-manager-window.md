# Issue 15 · BT Manager 窗口

Status: ready-for-agent
Sprint: 4 (UI)
Created: 2026-05-26
Updated: 2026-05-26
Related: [ADR-0004](../../../docs/adr/0004-swiftui-independent-windows.md), PRD US-3xx, US-4xx
BlockedBy: 06, 08

## 描述

SwiftUI 独立窗口（id `magnet.bt-manager`），承载 torrent 任务列表、控制、详情。

## 验收标准

- [ ] 注册 `Window(id: "magnet.bt-manager")`
- [ ] 主菜单 "Magnet > BT Manager…" + cmd+shift+B
- [ ] 顶部 Toolbar：
  - 添加按钮（弹出 sheet：粘贴 magnet / 拖入 .torrent）
  - 全部暂停 / 全部恢复
  - 全局速度信息（↑ 上传 ↓ 下载）
  - 搜索框（按 displayName 过滤）
- [ ] 主区域：`Table`
  - 列：名称、状态（chip）、进度（ProgressView）、速度（↓/↑）、peers、ETA
  - 右键菜单：暂停 / 恢复 / 删除（含 "同时删除文件" 选项）/ 复制 magnet / 在 Finder 中显示 / 双击播放
  - 双击行：调 `MagnetRouter.playStreaming(infoHash, fileIndex: 0)`（多视频文件场景下走 detail sheet 选择文件）
- [ ] Detail 抽屉（选中任务展开）：
  - Pieces 视图：可视化 piece bitfield（小方块网格，已下载绿色 / 未下载灰色 / 进行中黄色）
  - 文件列表（multi-file torrent）：每文件大小、进度、播放按钮
  - Trackers / Peers 信息（折叠）
- [ ] 拖拽支持：
  - 拖入 `.torrent` 文件到窗口 → 自动 `addTorrentFile`
  - 拖入 magnet 链接（剪贴板 / 来自浏览器） → `addMagnet`
- [ ] 接入 `TorrentManager.events` AsyncStream 实时刷新
- [ ] 操作权限：删除任务前确认 alert（含 "同时删除文件" toggle）
- [ ] 性能：100 个任务列表滚动流畅（60fps）
- [ ] 持久化：窗口关闭后任务继续在后台跑

## 实现提示

- `@Query` 拿 `[TorrentTask]`，状态更新由 `TorrentManager` actor 写入
- ProgressView 用 SwiftUI 内置 `.linear` style
- Pieces 视图：`LazyVGrid(columns: ...)` + 颜色 `Rectangle()`，bitfield 转 `[PieceState]`
- 拖拽：`.onDrop(of: [.fileURL, .text])`
- magnet 链接也可通过 `NSPasteboard` 监听？不必，统一 sheet 输入即可

## Out of scope

- 字幕提取的 UI 入口（Phase 2 整合到 Library；Phase 1 自动后台跑）
- 多任务播放队列（Phase 3+）

## Comments

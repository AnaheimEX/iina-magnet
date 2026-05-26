# Issue 07 · StreamPlanner 深模块

Status: ready-for-agent
Sprint: 2 (边看边播)
Created: 2026-05-26
Updated: 2026-05-26
Related: [ADR-0002](../../../docs/adr/0002-libtorrent-inproc.md), PRD §IM-6, US-27..30
BlockedBy: 06
Blocks: 08

## 描述

把"mpv 当前播放位置 + buffer 窗口 + 文件 piece map"转成"要给 libtorrent 设置的 piece deadline 列表"。**纯函数式深模块**。

## 验收标准

- [ ] `iina-magnet/Sources/IinaMagnet/Streaming/StreamPlanner.swift`
- [ ] API：
  ```swift
  struct PieceMap: Sendable {
      let pieceLength: Int        // bytes per piece
      let fileSize: Int64
      let downloaded: Set<Int>    // 已下载的 piece index
  }

  struct PieceDeadline: Sendable, Equatable {
      let piece: Int
      let deadlineMs: Int
  }

  struct StreamPlanner {
      static func plan(
          playerOffsetBytes: Int64,
          videoFileSizeBytes: Int64,
          videoFileStartOffsetInTorrent: Int64,  // 多文件 torrent 中视频文件在 torrent 内的字节偏移
          pieceMap: PieceMap,
          windows: PlannerWindows = .default
      ) -> [PieceDeadline]
  }

  struct PlannerWindows: Sendable {
      var urgentSeconds: Int   // 默认 30
      var nearSeconds: Int     // 默认 60
      var farSeconds: Int      // 默认 120
      var bitrateBytesPerSec: Int  // 默认 2 * 1024 * 1024（2MB/s 估算）
      static let `default` = PlannerWindows(urgentSeconds: 30, nearSeconds: 60, farSeconds: 120, bitrateBytesPerSec: 2 << 20)
  }
  ```
- [ ] 算法：
  - currentPiece = (videoFileStartOffsetInTorrent + playerOffsetBytes) / pieceLength
  - urgentPieces = pieces in [currentPiece, currentPiece + urgentSeconds * bitrate / pieceLength], deadline 0
  - nearPieces = 紧接其后的 nearSeconds 长度的 pieces, deadline 1000
  - farPieces = 紧接其后的 farSeconds 长度的 pieces, deadline 5000
  - **已下载的 piece 不输出 deadline**（避免重复设置）
  - **超过文件范围的 piece 不输出**
- [ ] 单元测试 ≥ 100% 覆盖：
  - 播放头在文件开始 → urgent 应该包含 piece 0
  - 播放头在文件中段 → urgent / near / far 边界
  - 播放头接近文件末尾 → far 不应超过文件最后一个 piece
  - 已下载 piece 不出现在输出中
  - pieceLength 不能整除 fileSize 时最后一个 piece 边界正确
  - bitrate / windows 改变时输出比例变化

## 实现提示

- 视频文件在 multi-file torrent 中的字节偏移：libtorrent `file_storage::file_offset(file_index)` 提供，由 Issue 06 在 status 中暴露
- 输出 deadline = 0 表示 "立刻"；libtorrent 实际值是 `set_piece_deadline(piece, deadline=0)`，由 wrapper 转
- 该模块不调 libtorrent，纯计算

## Out of scope

- PlayerCore 集成（→ Issue 08）

## Comments

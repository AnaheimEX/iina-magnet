# Issue 14 · 档案页跳播 + 版本切换

Status: completed (merged to develop)
Sprint: 3 (档案页 UI)
Created: 2026-05-29
Updated: 2026-05-29
Related: PRD §IM-8, US-19/20/22
BlockedBy: 13
Blocks: —

## 描述

把档案页的选集 / 播放按钮接到真实播放：通过 Phase 1 `IinaBridge` 打开 VersionFile。一集多版本时提供版本切换器，且集级进度跨版本共享（看 720p 第 3 集，1080p 也显示看过）。

## 验收标准

- [ ] `onPlay` 回调接 `IinaBridgeRegistry` → `openForPlayback(url:)`（复用 Phase 1，不新建桥）
- [ ] 一集多 VersionFile：UI 提供版本切换（清晰度 / 字幕组 / 文件大小），默认选最高清晰度
- [ ] 播放前校验 VersionFile.isMissing：缺失则禁用并提示"文件已移动/删除"
- [ ] "在 Finder 中显示"按钮（`NSWorkspace.activateFileViewerSelecting`）
- [ ] 进度角标基于 (title, season, episode) 读 WatchProgress —— 不分版本（验证 US-20：切版本仍显示同一进度）
- [ ] 集成 / 交互测试：
  - 选集调用 IinaBridge 且传对的 url（用假 bridge 断言）
  - 缺失文件不可播
  - 多版本切换不改变集级进度键

## 实现提示

- `IinaBridge` 在 Phase 1 已注册到 `IinaBridgeRegistry`（弱单例）；这里只取用
- 安全作用域：若 VersionFile 有 bookmark，播放前 `startAccessingSecurityScopedResource`
- 版本默认排序：resolution 数值降序 → 文件大小降序

## Out of scope

- 进度回写写入（→ Issue 17，这里只读取展示）

## Comments

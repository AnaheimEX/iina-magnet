# Issue 04 · LibraryService 扫描器（全量 + FSEvents 增量）

Status: ready-for-agent
Sprint: 1 (Schema + Scanner)
Created: 2026-05-29
Updated: 2026-05-29
Related: PRD §IM-5, ARCHITECTURE §2.3
BlockedBy: 01, 03
Blocks: 12, 19

## 描述

`actor LibraryService`：管理 scan roots，全量扫描（遍历视频文件 → FilenameParser → 产出候选 `ScannedFile`），FSEvents 增量监听（防抖 + 局部扫描），文件指纹去重，缺失检测。本 issue 只产出"候选 + 去重 + 缺失标记"，元数据查询与入库在 Issue 12。

## 验收标准

- [ ] `iina-magnet/Sources/IinaMagnet/Library/LibraryService.swift`（actor）
- [ ] scan roots：从 `AppSettings` 读（含 Phase 1 完成路径，见 Issue 20 迁移）；增删 API
- [ ] 视频扩展名白名单：`mkv mp4 m4v mov avi ts flv webm wmv rmvb`
- [ ] 全量扫描 `fullScan() -> AsyncStream<ScanProgress>`：`FileManager.enumerator` 分批；进度（已扫 / 估计总数 / 当前文件）经 stream 上报；可 `cancel()`
- [ ] `ScannedFile`：`url / fileFingerprint / sizeBytes / parsed: ParsedMedia`
- [ ] 指纹 `"<st_dev>:<st_ino>:<size>"`（`stat`）；与既有 VersionFile 比对，命中则标记"已存在"
- [ ] 缺失检测：扫描结束后，既有 VersionFile 对应文件不存在 → `isMissing=true`（不删记录）
- [ ] FSEvents：`iina-magnet/Sources/IinaMagnet/Library/FSEventsWatcher.swift`，监听 scan roots，500ms 防抖，事件折叠为受影响目录集合 → 触发局部扫描；专用 dispatch queue，回调转入 actor
- [ ] 单测（临时目录假文件树，Tests/fixtures/filetree/ 程序化构造）：
  - 全量扫描产出预期 ScannedFile 集合，忽略非视频与 .DS_Store
  - 同文件第二次扫描指纹命中、不重复
  - 删除文件后扫描标记缺失
  - 防抖：连续事件折叠为一次局部扫描（用假时钟 / 注入 debounce 间隔）
- [ ] 集成测试：构造 3 部作品的假文件树 → fullScan → 断言候选数量与解析结果

## 实现提示

- FSEvents 用 `FSEventStreamCreate` + `kFSEventStreamCreateFlagFileEvents`
- 进度估计总数可先快速浅枚举一遍目录计数，或用增量百分比近似
- actor 隔离：FSEvents C 回调里只投递路径，解析与状态变更回 actor

## Out of scope

- 元数据查询与 SwiftData upsert（→ Issue 12）
- 扫描进度 UI（→ Issue 19）

## Comments

# Issue 19 · 全量扫描进度 UI + 性能验收

Status: ready-for-agent
Sprint: 5 (待确认 + 验收)
Created: 2026-05-29
Updated: 2026-05-29
Related: PRD §TD-4
BlockedBy: 04, 12, 15
Blocks: —

## 描述

给全量扫描接进度 UI（可取消进度条），并补 Phase 2 的性能 gate 进 PerformanceTests，做端到端验收。

## 验收标准

- [ ] 扫描进度 UI：触发"全量扫描"→ 进度条（已扫/总数 + 当前文件名）+ 取消按钮；消费 Issue 04 的 `AsyncStream<ScanProgress>`
- [ ] 取消能中断遍历与后续元数据查询
- [ ] 增量扫描状态指示（FSEvents 触发时的轻提示）
- [ ] PerformanceTests 新增（参考 Phase 1 §TD-4 写法 + 预算）：
  - `FilenameParser.parse` 1000 次 < 100ms
  - `MetadataMerger.merge` 1000 次 < 50ms
  - 5000 文件假文件树 fullScan（仅遍历+解析，不联网）< 60s
- [ ] 端到端验收脚本/测试：构造 ~3 部作品假文件树 + 假 provider → fullScan → ingest → 断言库结构 + 三态初始值
- [ ] banner 错误提示：扫描/匹配错误（无 key、限流、读失败）在 Library 窗口顶部 banner + "查看日志"

## 实现提示

- perf 预算可像 Phase 1 那样在测试注释里写明 PRD 目标 vs 实测留余量
- 进度 UI 用 `.task` 消费 stream，取消用 Task cancellation 串到 LibraryService

## Out of scope

- 扫描器内核（→ Issue 04，本 issue 只接 UI + perf gate）

## Comments

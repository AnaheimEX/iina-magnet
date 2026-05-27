# Issue 18 · 性能压测与验收

Status: completed (merged to develop)
Sprint: 5 (验收)
Created: 2026-05-26
Updated: 2026-05-26
Related: PRD §Further Notes "性能预期"
BlockedBy: 14, 15, 17

## 描述

把 PRD 中"性能预期"的 4 项目标转成自动化基准测试，纳入 CI 性能 gating。

## 验收标准

- [ ] 基准目标（PRD §Further Notes）：
  - 同时 10 个 torrent，总下行 ≥ 20MB/s，mpv frame drop < 3%
  - libtorrent piece 完成 → mpv 可见时间 < 500ms
  - RssRuleEngine 1000 items × 50 rules < 50ms
  - 启动到 RSS Manager 可交互 < 1.5s
- [ ] `Tests/IinaMagnetPerf/` 独立 target：
  - `RssRuleEngineBench.swift`：XCTest `measure { ... }` 验证 < 50ms
  - `StreamPlannerBench.swift`：1万 piece map 计算 < 5ms
  - `StartupBench.swift`：模拟 App 启动到 Window appear，断言总时间
- [ ] BT 吞吐压测（手工 + 半自动）：
  - 在本地搭 10 个 libtorrent seed peers（用 fixture iso）
  - 启动 client 拉 10 个 torrent，观测速度
  - 用 `mpv --benchmark` 或 iina log 提取 frame drop
  - 文档化在 `docs/perf/benchmark-2026-05.md`
- [ ] piece → mpv 延迟测量：
  - 启用 debug log 记录 piece_finished 时间戳
  - 在 mpv `--msg-level=ffmpeg=trace`（或 iina mpv log）找对应 read 时间
  - 差值 → 写入测试报告
- [ ] CI gating：
  - `RssRuleEngineBench` 与 `StreamPlannerBench` 进入 PR 必跑
  - 启动 / BT 压测每 release 跑一次（手工）
- [ ] 不达标处理：
  - 立即开 issue，标 `ready-for-human`
  - 不阻塞 v0.1.0-phase1 release，但写入 known-issues

## 实现提示

- XCTest `measure` 用 `XCTMeasureOptions().iterationCount = 100` 提高统计稳定度
- 启动时间测量用 `os_signpost` + `MetricKit`（macOS 14+）
- BT 压测不进 CI（需要稳定网络环境）

## Out of scope

- Phase 2 性能（媒体库 scan / 查询）

## Comments

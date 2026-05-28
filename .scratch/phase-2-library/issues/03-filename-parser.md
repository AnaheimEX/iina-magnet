# Issue 03 · FilenameParser 深模块（Anitomy 主 + regex 兜底）

Status: ready-for-agent
Sprint: 1 (Schema + Scanner)
Created: 2026-05-29
Updated: 2026-05-29
Related: [ADR-0006](../../../docs/adr/0006-anitomy-bridge.md), PRD §IM-2
BlockedBy: 02
Blocks: 04, 11

## 描述

纯函数深模块 `FilenameParser.parse(_:) -> ParsedMedia`。先调 `ANTParser`，命中番剧则映射；否则走内置 regex 兜底（SxxExx / Name.Year / unknown）。任何输入都返回非 nil 结果。

## 验收标准

- [ ] `iina-magnet/Sources/IinaMagnet/Library/FilenameParser.swift`
- [ ] `ParsedMedia: Sendable, Equatable`：`title / season? / episode? / year? / resolution? / releaseGroup? / kindHint: MediaKind`
- [ ] 逻辑按 ADR-0006：
  - Anitomy 有 `anime_title` + `episode_number` → kind=.tv，映射各字段
  - 否则 regex：`S(\d+)E(\d+)`（大小写不敏感）→ tv；`(19|20)\d{2}` 且无集号 → movie；都不命中 → unknown，title=清洗后文件名
- [ ] title 清洗：去扩展名、去常见标签 `[...]`/`(...)`、归一空白
- [ ] fixture 单测 `Tests/fixtures/filenames/`（每条 {filename, expected}）覆盖：
  - 多字幕组番剧命名（喵萌 / LoliHouse / Nekomoe / 动漫花园）
  - 含中文作品名
  - 美剧 `Show.S01E03.1080p.WEB-DL.mkv`
  - 电影 `Movie.2021.2160p.BluRay.mkv`
  - 合集范围 `[01-12]`（episode 取起始或标记为 nil + season 级）
  - 纯垃圾名 → unknown 且 title 非空
- [ ] 性能 case 进 PerformanceTests：1000 次 parse < 100ms（PRD §TD-4）

## 实现提示

- 这是深模块——只暴露 `parse`，内部 Anitomy/regex 选择不外露
- regex 用预编译 `NSRegularExpression`（参考 Phase 1 RssRuleEngine 优化）
- resolution 归一：`2160p`/`4K`→"2160p"，`1080P`→"1080p"

## Out of scope

- 调元数据（→ Issue 11）
- 扫描目录（→ Issue 04）

## Comments

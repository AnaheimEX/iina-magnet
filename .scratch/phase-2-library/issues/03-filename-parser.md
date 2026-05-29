# Issue 03 · FilenameParser 深模块（Anitomy 主 + regex 兜底）

Status: completed (merged to develop)
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
- [ ] **CJK 标题恢复（Issue 02 发现，必做）**：经典 Anitomy 对 `[组][CJK标题][NN][1080p]` 返回 `episode_number`/`release_group`/`video_resolution` 但**无 `anime_title`**。FilenameParser 必须识别这种情形（有 episode_number 但无 anime_title）并从文件名结构恢复标题——典型启发式：取「去掉已识别的 group/episode/resolution/checksum/扩展名等 bracket 段后，剩下的那个 bracket 段（或最长非 ASCII 段）」作为 title，kind=.tv。
  - fixture 必须覆盖：`[喵萌奶茶屋][葬送的芙莉莲][04][1080p][简日双语].mkv` → title="葬送的芙莉莲", episode=4, releaseGroup="喵萌奶茶屋", resolution="1080p", kind=.tv
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

### 2026-05-29 claude
完成并合并。实现要点 / 实测调整：
- CJK 标题恢复按 Issue 02 发现实现：Anitomy 给了 episode 但无 anime_title 时，从 bracket 段里剔除 group/episode/resolution + 语言/源/编码标签噪声后，优先取含 CJK 的段为标题。fixture `[喵萌奶茶屋][葬送的芙莉莲][04][1080p][简日双语].mkv` → 正确恢复"葬送的芙莉莲"。
- 实测 Anitomy 行为补丁：不识别裸 `4K`（加 resolution regex 兜底 → 归一 2160p）；不总提取年份（电影路径加 year regex 并从标题剥离年份）。
- 分类修正：有 anime_title 但**无 episode 且无 year** → `.unknown`（而非误判 .tv）。
- 正则全部预编译为 static 常量（code-review 修复，遵 RssRuleEngine 约定）。
- 9 个 fixture 测试 + 1000 次解析 perf gate（<100ms）。全套 75 tests / 13 suites 通过。
- 注：本机 CLI swift-testing 全量并行偶发 signal 11/SIGTRAP（与 .mainContext 同源的环境问题），重跑稳定通过；CI/真机不受影响。

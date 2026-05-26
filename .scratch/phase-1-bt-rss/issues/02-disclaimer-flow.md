# Issue 02 · 首启动 Disclaimer 流程

Status: in-progress (PR #2 open, stacked on PR #1; CI pending)
Sprint: 0 (Foundation)
Created: 2026-05-26
Updated: 2026-05-26
Related: PRD §IM-8, US-38..41
BlockedBy: 01

## 描述

实现首启动强制 Disclaimer 弹窗（zh-Hans + en 双语），同意后才进主界面。Settings 中可再次查阅。Disclaimer 版本号变化时重弹。

## 验收标准

- [x] 资源文件 `Sources/IinaMagnet/Resources/Disclaimer.{zh-Hans,en}.md`（路径调整：移到 SPM 内部，`.process("Resources")` 打包）
- [x] `DisclaimerCoordinator`（@MainActor @Observable）：
  - [x] `static let currentVersion = "2026-05-26"`
  - [x] `func needsAcceptance() -> Bool`（同步即可——SwiftData fetch < 1ms，原 PRD 写 `async` 是不必要的）
  - [x] `func accept() throws`
- [x] `DisclaimerAcceptance` (@Model)：`@Attribute(.unique) version`, `acceptedAt`；加入 `PersistenceController.schema`
- [x] `DisclaimerSheet` SwiftUI：
  - [x] `Text(AttributedString(markdown:))` 渲染（不引入 MarkdownUI）
  - [x] Segmented Picker tab；默认按 `Locale.current.language.languageCode == "zh"`
  - [x] "我已阅读并同意 / I Have Read and Agree" 按钮，**仅滚动到底部后启用**（Color.clear sentinel + onAppear 实现）
  - [x] `keyboardShortcut(.defaultAction)` 把回车绑到按钮（disable 时也无效），无 cancel / esc 选项
- [ ] **DEFERRED to Issue 03**：iina 启动流程 hook（Bootstrap → AppDelegate）。原因：Phase 0 还没有 AppDelegate hook，模态展示需要等 Issue 03 接入。
- [ ] **DEFERRED to Issue 16**：Settings 中 "查看 Disclaimer" 入口。原因：Settings 窗口由 Issue 16 负责。
- [x] 单元测试：`needsAcceptanceOnEmptyDB`、`acceptFlipsTheFlag`、`acceptInsertsRow`、`staleVersionTriggersReprompt`、`currentVersionShape`（共 5 用例）
- [x] 集成测试（markdown 加载）：`chineseMarkdownLoads`、`englishMarkdownLoads` 校验 bundle 资源可读 + 内容关键词命中

## Disclaimer 文本要点（中英共有）

1. 本软件仅提供 RSS 与 BitTorrent 协议的技术能力
2. 用户须自行确保所下载/上传/传播的内容符合所在司法辖区的版权与其他法律
3. 项目作者不对用户使用本软件造成的任何后果负责
4. 本项目不提供、不索引、不推荐任何具体资源源
5. 用户可随时在 Settings 查阅本声明

## 实现提示

- `MarkdownUI` 是第三方，可避免引入；用系统 `Text(AttributedString(markdown:))` 足够
- `currentVersion` 改动属于法律变更，进 ADR / CHANGELOG，不允许悄悄改

## Out of scope

- 实际 Settings 主窗口的其他面板（Phase 1 后期 Issue 16）

## Comments

### 2026-05-27 · Claude Sonnet 4.6 实施会话

**完成**：
- PR: [#2 Disclaimer flow](https://github.com/AnaheimEX/iina-magnet/pull/2)，stack 在 PR #1 之上
- 9 个测试本地通过（含 Phase 0 烟测；3 suites）
- 资源迁到 SPM 内（`Sources/IinaMagnet/Resources/`），与 planning repo 副本 deduped（planning 中的旧 `iina-magnet/Resources/` 已删除，git 历史保留）

**未做（推迟）**：
- AppDelegate 入口（Issue 03 负责）：Bootstrap 当前是 stub，不接 coordinator
- Settings "查看 Disclaimer" 入口（Issue 16 负责）

**API 微调**：
- 原 PRD 写 `needsAcceptance() async -> Bool`。实际 SwiftData fetch 同步即可（< 1ms），无副作用，去 `async` 让调用方更简单。`@MainActor` 隔离已经覆盖 thread safety。
- 原 PRD 写 `accept() async`。同上，改成 `throws`。

**实现要点**：
- 滚动到底部判定：`Color.clear` 1pt 哨兵 + `.onAppear { ... }`。当 ScrollView 渲染到底部时哨兵首次 layout 触发回调。简单可靠，无需 GeometryReader / ScrollPosition API。
- Markdown 用 `.inlineOnlyPreservingWhitespace` 选项，保留段落换行，足够展示法律条款。
- 双语 currentVersion 同步：两份 markdown 文件 + DisclaimerCoordinator.currentVersion 必须三处保持一致；下次 bump 用 `git grep "2026-05-26"` 找全。
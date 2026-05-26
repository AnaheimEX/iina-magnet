# Issue 02 · 首启动 Disclaimer 流程

Status: ready-for-agent
Sprint: 0 (Foundation)
Created: 2026-05-26
Updated: 2026-05-26
Related: PRD §IM-8, US-38..41
BlockedBy: 01

## 描述

实现首启动强制 Disclaimer 弹窗（zh-Hans + en 双语），同意后才进主界面。Settings 中可再次查阅。Disclaimer 版本号变化时重弹。

## 验收标准

- [ ] 资源文件：
  - `iina-magnet/Resources/Disclaimer.zh-Hans.md`
  - `iina-magnet/Resources/Disclaimer.en.md`
- [ ] `DisclaimerCoordinator`（actor 或 `@Observable` 类）：
  - `currentVersion: String`（硬编码 const，如 `"2026-05-26"`）
  - `func needsAcceptance() async -> Bool`
  - `func accept() async`
- [ ] SwiftData model `DisclaimerAcceptance { version, acceptedAt }`，schema 加入 `PersistenceController.modelTypes`
- [ ] `DisclaimerSheet` SwiftUI 视图：
  - 用 `MarkdownUI` 或 `Text(AttributedString(markdown:))` 渲染 markdown
  - 顶部 tab：中文 / English，默认按系统 `Locale.current.language.languageCode`
  - 底部按钮：`同意 / I Agree`（仅滚动到底部后启用）
  - 不允许通过 cmd+W 或 esc 跳过
- [ ] iina 启动流程（在 Bootstrap）：
  - 主播放窗口出现前调 `DisclaimerCoordinator.needsAcceptance()`
  - true → 阻塞展示 sheet → 同意后写入 → 继续
  - false → 直接继续
- [ ] Settings 中加 "Disclaimer / 法律免责" 入口（独立 SwiftUI 窗口或 sheet），任何时候可看
- [ ] 单元测试：`DisclaimerCoordinator.needsAcceptance` 在不同 version 组合下的判定
- [ ] 集成测试：首次启动空数据库 → 需要展示；写入接受后 → 不展示；修改 currentVersion 后 → 重新展示

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

# iina-magnet — Claude Code Instructions

## 项目概述

iina-magnet 是 iina 的 fork，在保留原 macOS 播放器能力的基础上，新增 BT/RSS 订阅系统（Phase 1）与媒体库（Phase 2）。

- **许可证**：GPL-3.0（继承 iina）
- **最低系统**：macOS 14 Sonoma
- **技术栈**：Swift 5.9+, SwiftUI（新模块）, AppKit（iina 原有）, Obj-C++（libtorrent 桥接）, mpv（播放后端）
- **Upstream 策略**：long-running fork + 定期 merge `iina/iina`

---

## Agent skills

### Issue tracker

Issues / PRDs 以本地 Markdown 形式存放在 `.scratch/<feature>/` 下。详见 `docs/agents/issue-tracker.md`。

### Triage labels

默认五标签：`needs-triage` / `needs-info` / `ready-for-agent` / `ready-for-human` / `wontfix`。详见 `docs/agents/triage-labels.md`。

### Domain docs

Single-context 仓库。开始任何工作前先读 `CONTEXT.md` 与 `docs/adr/`。详见 `docs/agents/domain.md`。

---

## 工作约束

### Upstream 兼容

- **不要**重写 iina 原有的 AppKit 主窗口、播放控制、字幕渲染、mpv 桥接层。这些代码会在每周 merge upstream 时同步。
- **新功能**放在 `iina-magnet/` 顶层目录（与 iina 现有 `iina/` 平级），导入而不修改 iina 原模块。
- 必须修改 iina 原文件时，**集中在 hook 点**（如 `AppDelegate`、`PlayerCore`），且尽量小改动 + 注释 `// MARK: iina-magnet hook`。

### 决策落地

任何架构层面的不可逆决策（新依赖、新进程模型、新数据 schema）**必须先写 ADR**，再开始实现。ADR 写到 `docs/adr/NNNN-slug.md`。

### 测试

- 深模块（`RssRuleEngine`, `AnitomyParser`, `MetadataMerger`, `TorrentManager.pieceQueue`）必须有单元测试。
- BT/RSS/字幕的关键路径必须有集成测试（带固定 fixtures，不依赖网络）。
- UI 层不强制测试。

### 语言

- 文档 / 注释：中文优先（按用户偏好）；公开 API 文档块 + 提交说明用英文（便于 upstream 沟通）。
- 代码标识符：英文。
- 用户可见字符串：String Catalog（zh-Hans / en）。

---

## 提交规范

- Commit message：`<scope>: <imperative summary>`
- scope 例：`rss`, `bt`, `subs`, `library`, `ui`, `infra`, `docs`, `iina-sync`
- iina upstream merge：单独的合并 commit，message：`Merge upstream iina@<sha>`
- 不允许 squash 掉 upstream 合并的历史。

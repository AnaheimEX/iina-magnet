# ADR-0001 · Fork iina under GPL-3.0

Status: Accepted
Date: 2026-05-26

## Context

需要在 macOS 上拥有一个功能完整的播放器作为基础，再叠加 BT/RSS 订阅与媒体库能力。从 0 写一个能在生产用的播放器涉及：

- mpv / FFmpeg 封装与音视频解码
- 字幕渲染（ASS / SRT / PGS / VobSub）
- 硬件解码（VideoToolbox）
- macOS 原生手势 / TouchBar / OSC
- 多语言、设置面板、播放列表

工程量与 iina 多年沉淀的体量级相当（10w+ 行代码）。

## Decision

**Fork [iina/iina](https://github.com/iina/iina) 作为本项目代码基线**，在其之上以独立模块叠加新功能。

衍生约束：

- 项目以 **GPL-3.0** 发布（iina 已是 GPL-3.0，衍生作品必须兼容）
- 仓库布局：iina 原代码留在 `iina/`，新代码放 `iina-magnet/`，**只导入不修改** iina 模块
- **Long-running fork**：主分支始终跟 `iina/iina` 上游 develop，每 1-2 周 `git merge upstream/develop`。新功能在 `feature/*` 分支开发，完成后合入主分支

## Alternatives Considered

### A. 全新自研播放器

写一个新的 macOS 播放器，UI 与协议自定。

- ✗ 6+ 月才能达到 iina 现有播放体验
- ✗ 字幕渲染、硬解、手势这些"看不见的复杂"会反复消耗时间
- ✓ License 自由（可商业化）
- ✓ 无 upstream sync 负担

放弃理由：投入与产出严重不匹配，且本项目不打算商业化（见 [DEVELOPMENT_PLAN.md](../../DEVELOPMENT_PLAN.md) §2.1）。

### B. 做 iina 的外挂工具

主体不动 iina，做一个独立 App，通过 `iina://` URL Scheme 调起 iina。

- ✓ 不需 fork
- ✓ License 自由
- ✗ 无法集成到播放器 UI 内
- ✗ 边看边播无法绕过——iina 没有插件 hook 让我们提前 stream
- ✗ 用户体验割裂（两个 app）

放弃理由：边看边播需要在播放器进程内调度 piece，跨进程做不到。

### C. iina 官方插件系统

iina 有 JavaScript 插件 API（`@iina/script-loader`）。

- ✗ JS API 范围有限，主要做菜单/字幕辅助，不能注入 mpv stream
- ✗ 调试链路长，性能差

放弃理由：插件 API 不覆盖核心场景。

## Consequences

### 正面

- 用户开箱拿到完整 iina 体验 + 新能力
- 开发可以从第 1 天起专注做加分项（BT/RSS、媒体库），不重写已成熟功能
- 受益于 iina upstream 的 bug fix、mpv 升级、Apple Silicon 优化

### 负面与缓解

| 负面 | 缓解 |
| --- | --- |
| 必须开源 GPL-3.0，无法闭源商业化 | 项目本就不打算商业化（见 ADR 决策表） |
| 长期需要解决 upstream merge 冲突 | 严格控制对 iina 原文件的修改（hook 集中标记）；写自动化 sync 检查清单（`docs/sync-workflow.md`） |
| 不能改 iina 原 UI（避免冲突） | 新功能用 SwiftUI 独立窗口（[ADR-0004](./0004-swiftui-independent-windows.md)） |
| iina 一旦停止维护，fork 也会停滞 | 接受。本项目本身可作为 iina 的延续 |

## 实施约定

- iina 原文件只允许在 hook 点修改，每处加注释 `// MARK: iina-magnet hook`
- 所有新模块放 `iina-magnet/` 顶层目录
- 不允许在 iina 原模块新增对 iina-magnet 的引用（避免反向依赖）
- merge upstream 后必须跑完 CI（含集成测试）才能 push 主分支

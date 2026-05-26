# ADR-0004 · 新模块用 SwiftUI 独立窗口

Status: Accepted
Date: 2026-05-26
Related: [ADR-0001](./0001-fork-iina-gpl3.md)

## Context

新模块（RSS Manager、BT Manager、Library Browser、Archive Page）的 UI 实现方式有三种走法：

1. 嵌入 iina 现有主播放窗口（sidebar tab）
2. 全 SwiftUI 独立窗口，与 iina 主窗口并列
3. 重写 iina 主窗口为 SwiftUI

要权衡：
- upstream merge 冲突最小化
- 开发效率
- 用户使用动线（什么时候用浏览器、什么时候用播放器）

## Decision

**新模块全部用 SwiftUI，承载在独立窗口里**。iina 原 AppKit 主播放窗口**不动**。

四个独立窗口（Phase 1+2 累计）：

| Window ID | Phase | 说明 |
| --- | --- | --- |
| `magnet.rss-manager` | 1 | RSS 订阅源、规则、Feed 历史 |
| `magnet.bt-manager` | 1 | torrent 任务列表 |
| `magnet.library` | 2 | 媒体库总览 |
| `magnet.archive` | 2 | 作品档案页（每打开一部作品 +1 个） |

入口：iina 主菜单加一个 "Magnet" 顶层菜单，下挂四个 menu item。

跨窗口播放调度：用户在 Archive Page 点集 → 调 `MagnetRouter.play(versionFile)` → `PlayerCore.openURL(file)` → iina 主窗口前置 + 开始播放。

## Alternatives Considered

### A. 嵌入 iina 主窗口（sidebar tab）

把 RSS Manager / Library Browser 做成 iina 主窗口的 sidebar tab。

- ✓ 用户一个窗口完成所有事
- ✗ iina 主窗口是 AppKit，嵌 SwiftUI 需要 `NSHostingView`，混合管理复杂
- ✗ 改 iina 主窗口结构 = 修改 iina 原代码，**每次 upstream merge 都冲突**
- ✗ 主窗口适合"播放为中心"的全屏交互；浏览/管理操作硬塞进去 UX 别扭

放弃理由：upstream sync 风险 + UX 风险。

### B. 重写 iina 主窗口为 SwiftUI

把 iina 原 AppKit 主窗口也 SwiftUI 化。

- ✓ 风格统一
- ✗ 工程量数月起，且会与 upstream merge 彻底冲突
- ✗ 损失 iina 现有的字幕渲染 / OSC / 手势这些 AppKit 优势组件

放弃。直接与 [ADR-0001](./0001-fork-iina-gpl3.md) 决策"long-running fork"冲突。

### C. 选 b: 嵌入 + d: 主窗口播放保留

iina 主窗口只做播放（不动），但新加一个 AppKit 大窗口承载"管理"。

- ✓ AppKit 与 iina 风格一致
- ✗ 新模块代码也要 AppKit，开发效率低；与 SwiftData/Observation 不天然亲和
- ✗ 看不到 SwiftUI 的好处

放弃。AppKit 在新功能开发上效率劣于 SwiftUI。

## Consequences

### 正面

- iina 主窗口完全不改 → upstream merge 风险最低
- 新模块用 SwiftUI 5 + SwiftData，开发速度最快
- 用户动线清晰："管理在管理器，看片在播放器"，类似 iTunes / Music + QuickTime 的关系
- 多窗口符合 macOS 习惯

### 负面与缓解

| 负面 | 缓解 |
| --- | --- |
| 用户在窗口间切换需要 cmd+~ 或 Mission Control | 主菜单 + 全局快捷键（如 cmd+shift+R 打开 RSS Manager） |
| 多窗口 state 同步：从 Archive Page 触发播放后，需要把主窗口前置 | `MagnetRouter` 统一调度，调用 `NSApp.activate` + `playerWindow.makeKeyAndOrderFront` |
| 用户可能困惑"哪个窗口属于哪个 app" | 所有 iina-magnet 窗口 title 前缀 "Magnet —"；同一 Bundle ID |
| 全屏播放时 RSS Manager 仍可见在另一 Space | 接受。macOS 默认行为 |

## 实施约定

- 所有 SwiftUI 窗口入口在 `IinaMagnetApp.swift` 通过 `WindowGroup` / `Window` 注册
- 跨窗口通信走 `MagnetServices`（环境对象 / `@Observable` 单例），不直接互相 ref
- 主菜单注入：在 `AppDelegate.applicationDidFinishLaunching` 加一个 `// MARK: iina-magnet hook` 修改 main menu
- 用户首次打开任意 iina-magnet 窗口前必须已通过 Disclaimer 检查

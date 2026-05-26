# iina-magnet（寒骨）

> A magnet-aware, library-first fork of [iina](https://github.com/iina/iina) — 把 BT/RSS 订阅与媒体库带进现代 macOS 播放器。

**项目代号**：iina-magnet（寒骨）
**许可证**：GPL-3.0（fork 自 iina）
**最低系统**：macOS 14 Sonoma
**当前阶段**：📋 规划期（Phase 1 即将启动）

---

## 它做什么

在 iina 现有的播放/字幕/手势能力之上，扩展两套核心能力：

1. **BT / RSS 订阅系统**（Phase 1）—— RSS 多源订阅 + 关键词与正则规则 + libtorrent 边看边播 + 种子内字幕外挂提取。
2. **媒体库**（Phase 2）—— 元数据自动拉取（TMDB / Bangumi / Anilist / 豆瓣）+ 档案页 + 三态分类（未观看 / 在看 / 已看）+ FSEvents 资源扫描。

iina 原有的播放器主窗口（AppKit）保持不动，避免与 upstream 冲突；新模块以 SwiftUI 独立窗口承载。

---

## 文档地图

| 文档 | 用途 |
|---|---|
| [DEVELOPMENT_PLAN.md](./DEVELOPMENT_PLAN.md) | 完整开发计划（愿景、策略、Phase 划分、技术选型） |
| [ROADMAP.md](./ROADMAP.md) | 阶段路线图与里程碑 |
| [ARCHITECTURE.md](./ARCHITECTURE.md) | 系统架构与模块关系 |
| [CONTEXT.md](./CONTEXT.md) | 领域词汇表（与 agent 共享语言） |
| [docs/phase-1/PRD.md](./docs/phase-1/PRD.md) | Phase 1 PRD：BT/RSS 订阅系统 |
| [docs/adr/](./docs/adr/) | 架构决策记录（ADR） |

---

## 法律免责

本项目仅提供 BT 协议与 RSS 订阅的技术能力。用户须自行确保下载、上传与传播的内容符合所在司法辖区法律。项目作者不对用户使用本软件下载或传播的任何内容承担责任。详见首启动 Disclaimer。

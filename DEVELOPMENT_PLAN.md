# iina-magnet 开发计划主文档

> 这是整个项目的**总规划文档**。Phase 1/Phase 2 的细节分别在 [ROADMAP.md](./ROADMAP.md)、[ARCHITECTURE.md](./ARCHITECTURE.md)、[docs/phase-1/PRD.md](./docs/phase-1/PRD.md) 中展开。

---

## 1. 项目愿景

在 iina 现有的优秀播放体验上，让用户能 **"看到一个想看的就直接订阅、订阅完直接边下边播、看完即归档"**——把"找资源、下资源、整理资源、看资源"四步合并为一个连贯流程，在 macOS 原生体验下完成。

不做：
- 不做 Plex/Jellyfin 那样的**多设备 streaming server**（Phase 1/2 不做）
- 不做**社区/评论/分享**功能
- 不做**云存储集成**（NAS/WebDAV 暂不优先）

做：
- 让 BT/RSS 这个长期"工具流（μTorrent + Sonarr + Plex + IINA）"被一个 macOS 原生 app 流畅承接

---

## 2. 项目策略

### 2.1 Fork iina

详见 [ADR-0001](./docs/adr/0001-fork-iina-gpl3.md)。

- License：GPL-3.0（继承）
- 仓库布局：iina 原代码留在 `iina/`，本项目新增代码放 `iina-magnet/`，导入而不修改 iina 原模块
- Upstream sync：long-running fork，每 1-2 周 `git merge upstream/develop`
- 不重写 iina 的播放器主窗口、字幕渲染、mpv 桥接层

### 2.2 阶段切分

| Phase | 范围 | 时长 | 状态 |
| --- | --- | --- | --- |
| Phase 0 | fork 建立、工程基线、CI、Disclaimer | 1 周 | 待启动 |
| Phase 1 | BT/RSS 订阅 + 边看边播 + 字幕外挂 | 6-8 周 | 待启动 |
| Phase 2 | 媒体库 + 元数据 + 档案页 + 资源扫描 | 6-8 周 | 计划中 |
| Phase 3+ | 待定（在线字幕、Whisper 字幕生成、Bilibili/弹幕、多设备同步） | TBD | 未规划 |

### 2.3 工程原则

- 新模块（`iina-magnet/`）用 Swift 5.9+ / SwiftUI 5 / SwiftData。
- iina 接触面用 Obj-C 或 Swift 互操作，避免新引入 ABI 风险。
- libtorrent 桥接通过 Obj-C++（.mm）。详见 [ADR-0002](./docs/adr/0002-libtorrent-inproc.md)。
- 数据持久化全用 SwiftData（macOS 14+ 限定）。详见 [ADR-0003](./docs/adr/0003-swiftdata-persistence.md)。
- 不引入第三方 UI 框架（不用 PureLayout/SnapKit/Texture），直接 SwiftUI。
- 不引入大型反应式框架（不用 RxSwift），用 Swift Concurrency + Observation。

---

## 3. 关键技术决策一览

| 决策 | 选型 | ADR |
| --- | --- | --- |
| 项目基础 | Fork iina + 直接增强 | ADR-0001 |
| BT 引擎 | libtorrent (Rasterbar) 进程内桥接（Obj-C++） | ADR-0002 |
| 数据流 | sequential download → sparse file → mpv 直读路径 | ADR-0002 |
| 数据持久化 | SwiftData | ADR-0003 |
| 新模块 UI | SwiftUI 独立窗口（不嵌入主播放窗口） | ADR-0004 |
| 元数据 | 多源聚合：TMDB 主 / Bangumi+Anilist 番剧 / 豆瓣中文 | ADR-0005 |
| 文件名解析 | Anitomy（C++）包装为 Swift | — |
| 最低系统 | macOS 14 Sonoma | — |
| 做种策略 | 零做种（下载完即停） | — |
| RSS 规则模型 | include[] / exclude[] + 可选 regex | — |
| 观看进度粒度 | 集数级（跨多版本合并） | — |
| 同步策略 | Phase 1/2 不做多设备同步 | — |

---

## 4. 系统架构概览

详细图表与模块边界见 [ARCHITECTURE.md](./ARCHITECTURE.md)。这里只列顶层模块：

```
┌────────────────────────────────────────────────────────────┐
│                       iina (upstream)                      │
│   AppKit 主窗口 · PlayerCore · mpv bridge · 字幕渲染       │
└────────────────────────────────────────────────────────────┘
              ▲
              │ open file path（仅一向调用）
              │
┌────────────────────────────────────────────────────────────┐
│                    iina-magnet（新增）                     │
│                                                            │
│  SwiftUI 独立窗口：RSS Manager · Library Browser           │
│                                                            │
│  ┌──────────────┐ ┌────────────────┐ ┌──────────────────┐  │
│  │ RssService   │ │ TorrentManager │ │ LibraryService   │  │
│  │ - Feed 解析   │ │ - libtorrent   │ │ - SwiftData      │  │
│  │ - 规则匹配   │ │ - piece 队列   │ │ - 扫描器          │  │
│  │ - 轮询调度   │ │ - 字幕提取     │ │ - 元数据合并      │  │
│  └──────────────┘ └────────────────┘ └──────────────────┘  │
│         │                │                    │            │
│         └────────────────┴────────────────────┘            │
│                          │                                 │
│                  SwiftData (磁盘持久化)                    │
└────────────────────────────────────────────────────────────┘
```

依赖单向：iina-magnet → iina；不存在 iina → iina-magnet 反向依赖。

---

## 5. 风险与对策

| 风险 | 严重度 | 对策 |
| --- | --- | --- |
| libtorrent + Swift 互操作复杂、首次集成成本高 | 高 | Phase 0 用 1-2 天写 spike，先验证基础 piece 下载 + sparse 读取链路 |
| upstream merge 频繁冲突 | 中 | 严格控制 hook，注释标记，每周固定时间 merge |
| 多元数据源 API 限流 / 失效 | 中 | 本地缓存元数据；ProviderFactory 抽象，单源失败 fallback |
| mikanani 等站点反爬 | 中 | 支持 cookie/header 自定义；轮询区间可拉长；失败重试退避 |
| App Sandbox 限制（用户文件夹权限、网络 inbound） | 高 | Phase 0 选择是否启 Sandbox；建议 **不启 Sandbox**（与 BT 协议冲突，需 raw inbound socket） |
| 法律风险（BT 下载内容版权） | 中 | 强制首启动 disclaimer + 零做种策略 + 不内置 tracker 列表 |
| 测试覆盖不足导致 upstream merge 后回归 | 中 | 深模块强制单测；CI 必跑测试再 merge |
| SwiftData 在大数据集（>10k 条）下性能 / 迁移坑 | 中 | Phase 2 早做性能压测；准备 GRDB 作为 fallback |

---

## 6. 不在本计划范围内（暂不做）

- iOS / iPadOS 端
- 多设备同步（除非 Phase 3+ 明确启动）
- 自建 tracker / 自建索引站
- 在线流媒体播放（Bilibili / YouTube ／优酷之类）
- DLNA / AirPlay 投屏（iina 原生已有，不重做）
- 弹幕 / 评论系统
- 推荐算法 / 大数据分析
- 商业化（付费功能 / 订阅）

如果未来要做某项，需要新写一份 PRD 并通过 grill-with-docs 流程。

---

## 7. 文档变更协议

- 总体计划改动（新增 Phase、关键决策推翻）：本文档必须同步更新。
- 不可逆决策：写新 ADR，本文档表格补充指向。
- 已发布的 ADR 不能直接改，需新 ADR 引用旧 ADR 标 "Supersedes ADR-NNNN"。

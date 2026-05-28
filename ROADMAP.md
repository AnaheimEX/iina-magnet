# iina-magnet Roadmap

> 完整阶段路线图与里程碑。每个 Phase 完成后归档对应 PRD 到 `docs/<phase>/`。

---

## Phase 0 · Foundation（1 周）

**目标**：拥有一个能编译、能运行、能合并 upstream 的 fork。

### 任务

- [ ] Fork `iina/iina` 到 `iina-magnet`
- [ ] 升级最低系统至 macOS 14（修改 `Info.plist` / 项目配置）
- [ ] 顶层目录创建 `iina-magnet/` 模块，建立空 Swift target 与初始 SwiftUI 入口
- [ ] 接入 SwiftData，建立空 schema
- [ ] CI（GitHub Actions / Xcode Cloud 二选一）：
  - PR 触发：xcodebuild + Swift Test
  - main 触发：构建 release App Bundle artifact
- [ ] Disclaimer 弹窗（首启动一次，zh-Hans + en），Settings 入口
- [ ] 首个 upstream merge dry-run（建立 sync 工作流文档）
- [ ] `docs/sync-workflow.md`：写清 `git merge upstream/develop` 的步骤、回归测试清单

### 里程碑

- **M0.1**：能 `cmd+R` 跑起 iina-magnet，主窗口与原 iina 完全一致
- **M0.2**：能 merge upstream 并通过 CI
- **M0.3**：首启动弹 Disclaimer，同意后进入主界面

---

## Phase 1 · BT/RSS 订阅 + 边看边播（6-8 周）

**目标**：用户能添加 RSS 订阅源、配置规则、自动下载命中条目、边下边播。

详细 PRD：[docs/phase-1/PRD.md](./docs/phase-1/PRD.md)

### Sprint 拆分

#### Sprint 1（1 周）· libtorrent spike + 桥接

- libtorrent 编译为静态库（embed Boost）
- Obj-C++ wrapper：session 创建、torrent 添加、状态查询、暂停/恢复/删除
- Swift `TorrentManager` actor，包装 wrapper
- spike app：命令行模式启动一个 magnet，下到本地，**用 mpv 直接播放未完成文件**——验证 sparse 文件可读

#### Sprint 2（1.5 周）· 边看边播 + 字幕外挂

- `TorrentManager.setPieceDeadline()` 暴露给上层
- `StreamingPlanner`：mpv 当前播放偏移 → 估算 next pieces → 设置 deadline
- 字幕识别：完成的 sparse 文件检查 → 字幕扩展名 → 复制到视频同目录
- 集成测试：固定 `.torrent` fixture → 期望文件结构 → 期望字幕 sidecar

#### Sprint 3（1.5 周）· RSS 服务 + 规则引擎

- `RssService`：URL fetch + `XMLParser` 解析（RSS 2.0 / Atom），保留 cookie/header
- `RssRuleEngine`：deep module，input = `[FeedItem]` + `[Rule]`，output = `[Match]`
- `SubscriptionScheduler`：actor，按 `pollInterval` 调度，避开同时刻 burst
- 持久化：`SubscriptionSource`、`SubscriptionRule`、`FeedItem`（去重表）

#### Sprint 4（1.5 周）· UI 与流程串联

- SwiftUI 独立窗口：RSS Manager（订阅源列表、规则编辑、Feed 预览、Hit 历史）
- BT Manager（任务列表、进度、控制）
- 入口：iina 主菜单增加 "Magnet > RSS Manager / BT Manager"
- 流程串联：Match → enqueue → libtorrent 启动 → 完成 → 移动到媒体库根（Phase 2 才有"库"，Phase 1 移动到用户配置的"下载完成路径"）

#### Sprint 5（0.5-1 周）· 验收与文档

- 端到端验收：订阅 mikanani 类源 → 命中规则 → 边下边播 → 字幕自动加载
- 性能压测：同时 10 个 torrent、网速 20MB/s 下 mpv 不卡
- 用户文档：README 补 "如何添加订阅"、"如何写规则"
- Phase 1 PRD 归档；Phase 1 retro 写到 `.scratch/phase-1-bt-rss/retro.md`

### 里程碑

- **M1.1**（Sprint 1 末）：libtorrent 能下载 + mpv 能播 sparse 文件
- **M1.2**（Sprint 2 末）：边看边播稳定 + 字幕外挂自动加载
- **M1.3**（Sprint 3 末）：RSS 规则引擎单测通过 + 调度器能跑
- **M1.4**（Sprint 4 末）：UI 串通，能从 0 配置到自动下载完成
- **M1.5**（Sprint 5 末）：Phase 1 release tag `v0.1.0-phase1`

---

## Phase 2 · 媒体库 + 元数据 + 档案页（6-8 周）

> Status: 🚧 进行中 · PRD 与 20 个实施 issue 已落地：[PRD](./docs/phase-2/PRD.md) · [issues](./.scratch/phase-2-library/issues/) · [ADR-0005](./docs/adr/0005-multi-source-metadata.md) · [ADR-0006](./docs/adr/0006-anitomy-bridge.md)

**目标**：用户的本地视频（含 Phase 1 下载产物）自动入库、识别元数据、生成档案页、按三态分类浏览。

### Sprint 拆分

#### Sprint 1（1 周）· Schema + 扫描器

- SwiftData schema：Title / Season / Episode / VersionFile / Tag / WatchProgress
- `Scanner`：扫描根 → 文件遍历 → 文件名解析（Anitomy + 自研 regex 兜底）→ 候选 metadata 查询
- 增量监听：FSEvents → 防抖（500ms）→ 局部扫描

#### Sprint 2（1.5 周）· Metadata Providers

- `TMDBProvider`、`BangumiProvider`、`AnilistProvider`、`DoubanProvider`
- `MetadataMerger`：策略详见 ADR-0005
- 本地缓存（24h 默认）
- 多候选回查：相似度 < 阈值时进入 "待确认队列"

#### Sprint 3（1.5 周）· 档案页 UI

- SwiftUI：Backdrop + 海报 + 元信息 + 演职员 + 集数网格
- 集数网格点击 → 调用 iina PlayerCore 播放对应 VersionFile
- 多版本切换器（小箭头切版本，保留集级进度）

#### Sprint 4（1.5 周）· 媒体库总览 + 三态 + 统计块

- 列表/网格切换
- 筛选：未看 / 在看 / 已看 / 标签 / 类型
- 统计块（底部固定）：tv / movie / unknown 计数 + 点击跳筛选
- 标签编辑器（自动 + 手动）

#### Sprint 5（0.5-1 周）· 待确认队列 UI + 验收

- 多匹配候选时弹"选择正确作品"对话框
- 全量扫描进度条（cancelable）
- 性能压测：5000+ 文件扫描在合理时间（目标 < 60s 增量、< 5min 全量）

### 里程碑

- **M2.1**：单部电影/单部剧能自动识别 metadata
- **M2.2**：番剧（Anitomy 命名）能识别 + 走 Bangumi.tv
- **M2.3**：档案页能跳播
- **M2.4**：三态 + 统计块工作
- **M2.5**：Phase 2 release tag `v0.2.0-phase2`

---

## Phase 3+ · 待定

候选方向（不承诺时间）：

- 在线字幕搜索（射手网 / OpenSubtitles）
- Whisper.cpp 本地字幕生成
- Bilibili / 弹幕集成
- 多设备同步（CloudKit）
- 推荐 / 热门 / 相似作品
- 自动质量升级（自动用 1080p 替换 720p）
- iCloud / 备份 / 导入导出
- iOS / iPadOS 同步

进入 Phase 3+ 前需要重新走 grill-me / grill-with-docs，并补 PRD。

---

## 工时与人力假设

文档假设 **1 个开发者 + Claude Code 辅助** 在业余时间投入（约 15-20h/周）。

如果是 **全职单人**（40h/周）：

- Phase 0：2-3 天
- Phase 1：3-4 周
- Phase 2：3-4 周

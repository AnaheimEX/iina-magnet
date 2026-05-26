# iina-magnet 系统架构

> 系统模块、边界、依赖、关键数据流。Phase 1 与 Phase 2 合并在一张图里。

---

## 1. 顶层视图

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                          iina-magnet.app（macOS Bundle）                     │
│                                                                              │
│  ┌────────────────────────────────────┐  ┌──────────────────────────────┐    │
│  │            iina（upstream）        │  │      iina-magnet（新增）     │    │
│  │                                    │  │                              │    │
│  │  AppKit MainWindow                 │  │  SwiftUI Independent Windows │    │
│  │  PlayerCore (mpv)                  │  │  - RSS Manager Window        │    │
│  │  Subtitle Renderer                 │  │  - BT Manager Window         │    │
│  │  Gestures · OSC · Settings         │  │  - Library Browser Window    │    │
│  │                                    │  │  - Archive Page Window       │    │
│  └─────────────┬──────────────────────┘  └────────────┬─────────────────┘    │
│                │                                      │                      │
│                │  PlayerCore.openURL(file://...)      │ ServiceLayer         │
│                ▲                                      ▼                      │
│                │                          ┌──────────────────────────┐       │
│                └──────────────────────────┤ MagnetRouter              │       │
│                                           │ ("打开 X" 入口的统一调度)│       │
│                                           └────────────┬─────────────┘       │
│                                                        │                     │
│  ┌─────────────────────────────────────────────────────┴──────────────────┐  │
│  │                            Service Layer                               │  │
│  │                                                                        │  │
│  │  RssService     TorrentManager     LibraryService    MetadataService   │  │
│  │  ───────────    ──────────────     ───────────────   ────────────────  │  │
│  │  - Fetcher      - libtorrent       - Scanner         - TMDBProvider    │  │
│  │  - Parser       - PieceQueue       - FSEventsWatch   - BangumiProvider │  │
│  │  - RuleEngine   - StreamPlanner    - Ingester        - AnilistProvider │  │
│  │  - Scheduler    - SubExtractor     - PathMover       - DoubanProvider  │  │
│  │                                                       - Merger         │  │
│  │                                                                        │  │
│  └────────────────────────────────┬───────────────────────────────────────┘  │
│                                   │                                          │
│  ┌────────────────────────────────┴───────────────────────────────────────┐  │
│  │                         Persistence Layer                              │  │
│  │                                                                        │  │
│  │  SwiftData (主存储)         FileSystem (Cache + 媒体库根)              │  │
│  │  ├ Subscription             ├ ~/Library/.../cache/<infoHash>/...       │  │
│  │  ├ Rule                     ├ <user-configured-roots>/                 │  │
│  │  ├ FeedItem (dedup)         └ Subtitles (sidecar to videos)            │  │
│  │  ├ TorrentTask                                                         │  │
│  │  ├ Title / Season / Episode / VersionFile                              │  │
│  │  ├ Tag                                                                 │  │
│  │  ├ WatchProgress                                                       │  │
│  │  └ Disclaimer (是否同意)                                               │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │                         Native Bridge Layer                            │  │
│  │                                                                        │  │
│  │  LibtorrentBridge.mm     AnitomyBridge.mm    mpv (already in iina)     │  │
│  │  ─────────────────────   ─────────────────                             │  │
│  │  Obj-C++ wraps           Obj-C++ wraps                                 │  │
│  │  libtorrent::session     Anitomy::Tokenize                             │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 模块详述

### 2.1 iina（upstream）

**只读使用**。仅通过两个稳定接口与 iina-magnet 交互：

- `PlayerCore.openURL(URL, opts)` —— 命令 iina 播放指定文件
- `AppDelegate` 中注册一个或两个菜单项入口（iina-magnet hook）

不修改 iina 的：mpv 桥接、字幕渲染、手势、OSC、播放列表、Settings 主面板。

### 2.2 SwiftUI 独立窗口

四个新窗口，全部 SwiftUI 实现：

| 窗口 | Phase | 职责 |
| --- | --- | --- |
| RSS Manager | 1 | 订阅源 CRUD、规则编辑、Feed 预览、命中历史 |
| BT Manager | 1 | torrent 任务列表、进度、控制、删除 |
| Library Browser | 2 | 媒体库总览（grid/list）、筛选、统计块 |
| Archive Page | 2 | 作品详情、集数网格、版本选择、跳播 |

通过 `NSApp.openWindow(id:)`（SwiftUI 4+）调用。窗口之间不共享 state，全部通过 Service Layer 拿数据。

### 2.3 Service Layer

#### RssService（Phase 1）

```
Fetcher  ──fetch(URL, cookies, headers)──>  raw XML/Atom
Parser   ──parse(raw)──> [FeedItem]
RuleEngine ──evaluate([FeedItem], [Rule])──> [Match]
Scheduler  ──按 pollInterval 调度上述链路──> Match 落 SwiftData
```

`RuleEngine` 是**深模块**：纯函数、易测试、独立于 IO。input/output 在 [docs/phase-1/PRD.md](./docs/phase-1/PRD.md) 中描述。

#### TorrentManager（Phase 1）

```
SwiftActor 持有 libtorrent::session*
公开 API：addMagnet / addTorrentFile / pause / resume / remove / status(stream)
内部子模块：
  - PieceQueue：基于 mpv 当前播放偏移 + 缓冲窗口估算优先 piece
  - StreamPlanner：set_piece_deadline 调用器
  - SubtitleExtractor：扫描已完成 piece 区域内的 .srt/.ass 等
```

#### LibraryService（Phase 2）

```
Scanner ──遍历 scan roots──> Candidate FileInfo
Anitomy ──parse(filename)──> AnimeFields | nil
RegexFallback ──parse──> EpisodeFields
MetadataService.query(title, year, season, episode) ──> [MetadataCandidate]
Merger ──合并 candidates──> CanonicalMetadata
Ingester ──upsert SwiftData──> Title/Season/Episode/VersionFile
FSEventsWatch ──监听──> Scanner 局部触发
```

#### MetadataService（Phase 2）

```
ProviderRegistry：[TMDBProvider, BangumiProvider, AnilistProvider, DoubanProvider]
QueryRouter：根据"作品类型猜测" + "用户配置优先级" 决定查询顺序
Cache：按 (providerId, externalId, locale) 24h LRU
Merger：策略见 ADR-0005
```

### 2.4 Persistence Layer

#### SwiftData Schema（汇总）

```swift
@Model class SubscriptionSource {
    var url: URL
    var displayName: String
    var pollInterval: TimeInterval  // 秒
    var cookieHeader: String?
    var customHeaders: [String: String]
    var enabled: Bool
    var rules: [SubscriptionRule]
}

@Model class SubscriptionRule {
    var name: String
    var include: [String]
    var exclude: [String]
    var regex: String?  // nil = 不用正则
    var enabled: Bool
}

@Model class FeedItem {
    var guid: String  // 用于去重
    var title: String
    var enclosureURL: URL
    var publishedAt: Date
    var sourceId: PersistentIdentifier
    var matched: Bool
}

@Model class TorrentTask {
    var infoHash: String
    var savePath: URL
    var displayName: String
    var status: TaskStatus  // .resolving / .downloading / .paused / .completed / .failed / .removed
    var progress: Double
    var addedAt: Date
}

@Model class Title {           // Phase 2
    var tmdbId: Int?
    var bangumiId: Int?
    var anilistId: Int?
    var titleZh: String?
    var titleEn: String?
    var titleJa: String?
    var kind: MediaKind  // .tv / .movie / .unknown
    var overview: String?
    var posterURL: URL?
    var backdropURL: URL?
    var releaseYear: Int?
    var seasons: [Season]
    var tags: [Tag]
}

@Model class Season {          // Phase 2
    var number: Int
    var episodes: [Episode]
    var title: Title
}

@Model class Episode {         // Phase 2
    var number: Int
    var title: String?
    var airDate: Date?
    var overview: String?
    var versions: [VersionFile]
    var progress: WatchProgress?
}

@Model class VersionFile {     // Phase 2
    var url: URL
    var resolution: String?
    var releaseGroup: String?
    var languages: [String]
    var fileSize: Int64
}

@Model class Tag {             // Phase 2
    var name: String
    var category: TagCategory  // .genre / .year / .country / .ratingBucket / .quality / .releaseGroup / .userDefined
}

@Model class WatchProgress {   // Phase 2
    var titleId: PersistentIdentifier
    var seasonNumber: Int?
    var episodeNumber: Int?
    var lastPosition: TimeInterval
    var duration: TimeInterval
    var state: ProgressState  // .unseen / .inProgress / .completed
    var updatedAt: Date
}

@Model class DisclaimerAcceptance {
    var version: String
    var acceptedAt: Date
}
```

### 2.5 Native Bridge Layer

#### LibtorrentBridge.mm

Obj-C++ class（`.mm`）。理由：libtorrent 是 C++ 库，必须用 C++ 编译单元；Obj-C++ 让 Swift 通过 Obj-C 头文件桥接。

公开的 Obj-C 接口仅暴露原生类型（`NSString`、`NSData`、整数）。libtorrent 类型不外泄。

#### AnitomyBridge.mm

类似处理。Anitomy 输入 `NSString` 文件名，输出 `NSDictionary` 解析字段。

---

## 3. 关键数据流

### 3.1 RSS 订阅命中 → 边看边播 → 字幕加载

```
[Scheduler tick]
        │
        ▼
[Fetcher.fetch(source)]──HTTP+cookies──>[raw XML]
        │
        ▼
[Parser.parse(xml)] → [FeedItem array]
        │
        ▼
[去重表查询] → 过滤已存在 guid → [新 FeedItem array]
        │
        ▼
[RuleEngine.evaluate(items, source.rules)] → [Match array]
        │
        ▼
[TorrentManager.addMagnet(match.enclosureURL)] ─┐
        │                                       │
        ▼                                       │
[libtorrent session 开始下载]                   │
        │                                       │
        ├─piece 0 完成→ 元数据写入 sparse file  │
        │                                       │
        ├─用户在 BT Manager 双击任务            │
        │                                       │
        ▼                                       │
[StreamPlanner.startStreaming(task)]            │
[PieceQueue 设置 piece 0..N deadline=urgent]    │
        │                                       │
        ▼                                       │
[PlayerCore.openURL(file://sparse-file)]        │
        │                                       │
        ▼                                       │
[mpv 读 sparse file ── 命中空洞 ── 短 buffer 等待 piece]
        │
        │(mpv seek 或播放推进)
        ▼
[StreamPlanner 调整 piece deadline 窗口]
        │
        │(下载完成事件)
        ▼
[SubtitleExtractor 扫描已完成区域]
        │
        ▼
[识别 .srt/.ass 等 → 复制到视频 sidecar 路径]
        │
        ▼
[mpv 自动加载 sidecar 字幕]
```

### 3.2 资源扫描 → 元数据匹配 → 入库

```
[用户点击 "全量扫描" or FSEvents 触发]
        │
        ▼
[Scanner 遍历 scan roots]
        │
        ▼
[文件 mime/extension 过滤 → 候选视频]
        │
        ▼
[Anitomy.parse(filename)]
    │
    ├─成功（番剧命名）→ 用 anime_title / episode_number 查 Bangumi
    │
    └─失败 → RegexFallback 提取 series + episode → 查 TMDB
        │
        ▼
[ProviderRegistry 多源并发查询]
        │
        ▼
[候选结果按相似度排序]
    │
    ├─top 相似度 ≥ 阈值 → Merger 合并 → upsert 入库
    │
    └─不达阈值 → 进 "待确认队列"
        │
        ▼
[用户从待确认队列点击候选] → 用户选定 → 入库
```

---

## 4. 依赖关系图

```
SwiftUI Windows ──> Service Layer ──> Persistence
       │                  │
       │                  ├──> Native Bridge (libtorrent / Anitomy)
       │                  │
       │                  └──> 外部 HTTP API (TMDB / Bangumi / Anilist / 豆瓣 / RSS 源)
       │
       └──> iina PlayerCore (仅 openURL)
```

依赖单向，无环。任何想引入新的反向依赖（如让 iina 主窗口调 Library）必须先写 ADR。

---

## 5. 进程与线程模型

- **单进程**：libtorrent + mpv + UI 全在 iina-magnet.app 主进程。详见 [ADR-0002](./docs/adr/0002-libtorrent-inproc.md)。
- **主线程**：仅 UI（SwiftUI / AppKit）。
- **网络与磁盘 IO**：Swift Concurrency `actor`（`RssService`, `TorrentManager`, `LibraryService`, `MetadataService` 全部为 actor）。
- **libtorrent 内部线程**：libtorrent 自管理；Swift 侧通过 alert pumping（轮询）拿事件。
- **FSEvents**：在专用 dispatch queue 上回调，事件转入 `LibraryService.actor`。

---

## 6. 错误与可观测性

- 日志：`os_log` + 自定义 Logger，子系统按模块划分（`rss`、`bt`、`lib`、`meta`）。
- 崩溃：让 macOS Crash Reporter 处理；不内置 telemetry（隐私优先）。
- 用户可见错误：以 SwiftUI banner / sheet 形式提示，含 "查看日志" 入口（打开 `Console.app` 过滤本 app）。
- 调试：debug build 在 RSS Manager 加 "查看 Feed 原始 XML"、"导出 RuleEngine 输入/输出" 入口。

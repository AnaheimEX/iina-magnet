# PRD · Phase 2：媒体库 + 元数据 + 档案页

Status: ready-for-agent
Phase: 2
Created: 2026-05-29
Owner: iina-magnet maintainers
Target Release: v0.2.0-phase2
Estimated Effort: 6-8 weeks

> 本文档沿用 Phase 1 PRD 模板。Phase 2 完成后归档不再修改；调整通过新 PR 与新 ADR 协作。
> 关键决策见 [ADR-0005（多源元数据）](../../docs/adr/0005-multi-source-metadata.md) 与 [ADR-0006（Anitomy 桥接）](../../docs/adr/0006-anitomy-bridge.md)。

---

## Problem Statement

Phase 1 解决了"订阅 → 下载 → 边看边播 → 字幕"。但下载完成的文件只是落在用户配置的"下载完成路径"里，散落成一堆 `<torrent 名>/...` 子目录：

- 我有几百集番剧、几十部电影散在硬盘上，**找一部想看的要靠记文件名**。
- 同一部作品我可能有多个版本（720p 旧版 + 1080p 新版 + 不同字幕组），它们是独立的文件夹，**看不出是同一部作品**。
- 我不知道**哪些看过、哪些在看、哪些还没开始**——进度全靠脑子记。
- 文件名是 `[Nekomoe kissaten][Boku no Hero Academia][01][1080p].mkv` 这种，**没有海报、没有简介、没有演职员**，浏览体验等于在 Finder 里翻文件。
- 我希望像 Plex / Infuse 那样有"作品档案页"，但**不想架服务器、不想全家桶**，就在这台 Mac 上、在我已经用的播放器里完成。

## Solution

在 iina-magnet 里新增第三个功能区 **Library（媒体库）**，一个独立 SwiftUI 窗口：

1. **扫描** —— 把用户配置的 scan roots（含 Phase 1 的"下载完成路径"）里的视频文件自动遍历、解析文件名、识别为"作品 / 季 / 集 / 版本文件"。
2. **元数据** —— 多源聚合（TMDB / Bangumi / Anilist / 豆瓣，见 ADR-0005）拉取海报、简介、演职员、集数信息，合并为一条权威记录。
3. **档案页** —— 每个作品一张档案页：backdrop + 海报 + 元信息 + 演职员 + 集数网格。点击集数直接在 iina 主窗口播放。
4. **总览 + 三态** —— 网格 / 列表浏览全部作品，按"未看 / 在看 / 已看 / 标签 / 类型"筛选，底部统计块。
5. **进度跟踪** —— 播放进度回写，集数级（跨版本合并），驱动三态。
6. **待确认队列** —— 自动识别不确定时（相似度落在中间区间）进入待确认队列，用户从候选中选正确作品。

入库流程：

```
用户配置 scan roots（默认含 Phase 1 下载完成路径）
  ↓
Scanner 遍历 / FSEvents 增量监听 → 候选视频文件
  ↓
FilenameParser（Anitomy + regex 兜底）→ {作品名, 季, 集, 版本字段}
  ↓
MetadataService 多源查询 → 每源 top-3 候选
  ↓
MetadataMerger 按 ADR-0005 字段优先级合并 → CanonicalMetadata + 相似度
  ↓
相似度分流：≥0.85 自动入库 / 0.65–0.85 入库待确认 / <0.65 进待确认队列
  ↓
Ingester upsert → Title / Season / Episode / VersionFile（SwiftData）
  ↓
用户在 Library 浏览 → 打开档案页 → 点集数 → iina 播放
  ↓
播放进度回写 WatchProgress → 驱动三态
```

---

## User Stories

### 扫描与入库（US-1xx）

1. 作为用户，我想配置一个或多个"扫描根目录"（默认自动包含 Phase 1 的下载完成路径），以便 app 知道去哪里找我的视频。
2. 作为用户，我想点击"全量扫描"，把所有 scan roots 里的视频文件遍历入库，并看到进度条（可取消）。
3. 作为用户，我希望新文件落到 scan root 后能被自动增量识别入库（FSEvents 监听 + 防抖），不用每次手动扫。
4. 作为用户，我希望扫描只处理视频文件（按扩展名白名单），忽略字幕 / 临时文件 / `.DS_Store` 等。
5. 作为用户，我希望已入库的文件再次扫描时被识别为同一条记录（按文件 inode / 路径 + 大小指纹去重），不重复创建。
6. 作为用户，我希望文件被移动 / 删除后，库里的 VersionFile 能反映"文件缺失"状态而不是显示一个死链。
7. 作为用户，我希望番剧文件名（`[字幕组][作品名][集数][清晰度]`）能被正确解析出作品名与集数。
8. 作为用户，我希望非番剧命名（`Movie.Name.2021.1080p.BluRay.x264.mkv` / `Show.S01E03.mkv`）也能通过 regex 兜底解析出片名 / 季 / 集。

### 元数据（US-2xx）

9. 作为用户，我想让 app 自动为识别出的作品拉取元数据（海报、简介、年份、演职员、集数表）。
10. 作为用户（番剧主导），我希望番剧优先走 Bangumi.tv 拿声优 / 制作信息，电影 / 美剧走 TMDB。
11. 作为用户，我希望中文片名 / 中文简介 / 中文演员名质量优先（豆瓣 → TMDB-zh）。
12. 作为用户，我想在 Settings 填写 TMDB / Bangumi 的 API key（不内置 key），并能开关豆瓣源。
13. 作为用户，我希望单个元数据源失败（限流 / 反爬 / 超时）时不阻塞其它源，作品仍能拿到可用的部分元数据。
14. 作为用户，我希望元数据有本地缓存（默认 24h），并能对单个作品手动"刷新元数据"跳过缓存。
15. 作为用户，当自动匹配不确定时，我希望该作品进入"待确认队列"，我能从候选列表里选出正确作品（看海报 + 年份辅助判断）。
16. 作为用户，我希望对匹配错误的作品手动"重新匹配 / 改绑"到正确的 TMDB / Bangumi 条目。

### 档案页（US-3xx）

17. 作为用户，我想打开一个作品的档案页，看到：backdrop 背景、海报、中文标题（+原标题）、年份、类型、评分（TMDB + 豆瓣并列）、简介、演职员。
18. 作为用户（剧集 / 番剧），我想在档案页看到按季分组的集数网格，每集显示集号 / 标题 / 是否看过 / 进度。
19. 作为用户，我想点击集数网格里的某一集，直接在 iina 主窗口播放对应文件。
20. 作为用户，当一集有多个版本文件（不同清晰度 / 字幕组）时，我希望能切换选择播放哪个版本，且**集级进度跨版本共享**（看了 720p 第 3 集，换 1080p 仍显示看过）。
21. 作为用户（电影），我希望档案页直接有"播放"按钮（电影无集数网格）。
22. 作为用户，我希望在档案页能看到每个 VersionFile 的清晰度 / 字幕组 / 文件大小 / 语言，并能"在 Finder 中显示"。

### 总览与浏览（US-4xx）

23. 作为用户，我想在 Library 总览里以网格（海报墙）或列表两种方式浏览全部作品，并能切换。
24. 作为用户，我想按"未看 / 在看 / 已看"三态筛选作品。
25. 作为用户，我想按类型（电影 / 剧集 / 番剧 / unknown）筛选。
26. 作为用户，我想按标签（genre / 年份 / 国家 / 字幕组 / 自定义）筛选。
27. 作为用户，我想搜索作品（按中文 / 原文标题模糊匹配）。
28. 作为用户，我想在底部看到固定的统计块：tv / movie / unknown 数量，点击某项即跳到对应筛选。
29. 作为用户，我想给作品打自定义标签，也希望系统按 genre / 年份 / 国家 / 清晰度 / 评分档自动生成标签。

### 进度与三态（US-5xx）

30. 作为用户，我希望播放某集到一定比例（默认 ≥90%）后自动标记为"已看"。
31. 作为用户，我希望中途退出的集显示"在看"状态并记住播放位置，下次从该位置续播。
32. 作为用户，我希望一部剧"全部集已看"时整部作品标记为"已看"，"有看过但未全看完"为"在看"，"一集都没开始"为"未看"。
33. 作为用户，我想手动把某集 / 某作品标记为已看 / 未看（覆盖自动判定）。

### 启动 / 迁移（US-6xx）

34. 作为 Phase 1 老用户升级到 Phase 2，我希望我历史下载的所有文件（在下载完成路径里）首次启动 Phase 2 时被自动加入 scan roots 并全量扫描入库。
35. 作为用户，我希望 Library 菜单项在 Phase 2 被启用（Phase 1 里是灰色占位）。

### 可观测性（US-7xx）

36. 作为用户，扫描 / 匹配出错时（API key 无效、限流、文件无法读取）我希望在 Library 窗口看到 banner 提示，并能查看详细日志。
37. 作为高级用户 / 开发者，debug build 我希望能查看某作品的"原始多源匹配 JSON + 合并决策"，以便排查匹配错误。

---

## Implementation Decisions

> 不含具体文件路径与代码片段（除非该片段精确编码了决策）。文件路径在实现 issue 中描述。

### IM-1 · 模块归属

Phase 2 新代码全部放 `iina-magnet/Sources/IinaMagnet/Library/` 与 `iina-magnet/Sources/IinaMagnet/Metadata/` 下；Anitomy 桥接放独立 SwiftPM target `AnitomyBridge`（与 `LibtorrentBridge` 平级）。iina 原代码仅在已有 hook 点扩展（播放进度回写）。

### IM-2 · 核心深模块（必须单测）

1. **`FilenameParser`** —— 纯函数 `parse(filename: String) -> ParsedMedia`。内部先调 Anitomy，失败 fallback 到内置 regex。输出统一结构 `{ title, season?, episode?, year?, resolution?, releaseGroup?, kind推测 }`。
2. **`MetadataMerger`** —— 纯函数 `merge([ProviderID: MetadataDetails]) -> CanonicalMetadata`。按 ADR-0005 字段优先级表。100% 行覆盖。
3. **`SimilarityScorer`** —— 纯函数 `score(parsed: ParsedMedia, candidate: MetadataCandidate) -> Double`。标题 Levenshtein + 年份 + 季集加权（ADR-0005）。
4. **`TagDeriver`** —— 纯函数 `derive(CanonicalMetadata, VersionFile) -> [Tag]`。自动生成 genre/year/country/quality/ratingBucket 标签。

### IM-3 · Anitomy 桥接

详见 [ADR-0006](../../docs/adr/0006-anitomy-bridge.md)。`AnitomyBridge` 暴露最小 Obj-C 接口：

```objc
@interface ANTParser : NSObject
+ (nullable NSDictionary<NSString *, id> *)parse:(NSString *)filename;
@end
```

返回 dict 的 key 用 Anitomy 的 element 名（`anime_title` / `episode_number` / `anime_season` / `video_resolution` / `release_group` / `anime_year` 等）。Swift 侧 `FilenameParser` 把它映射到 `ParsedMedia`。

### IM-4 · Phase 2 SwiftData schema

与 [ARCHITECTURE.md §2.4](../../ARCHITECTURE.md) 一致：

```swift
@Model class Title {
    var tmdbId: Int?
    var bangumiId: Int?
    var anilistId: Int?
    var doubanId: String?
    var titleZh: String?
    var titleEn: String?
    var titleJa: String?
    var kind: MediaKind            // .tv / .movie / .unknown
    var overview: String?
    var posterURL: URL?
    var backdropURL: URL?
    var releaseYear: Int?
    var tmdbRating: Double?
    var doubanRating: Double?
    var matchState: MatchState     // .confirmed / .pendingConfirmation / .unmatched
    var matchScore: Double
    var seasons: [Season]          // @Relationship cascade
    var tags: [Tag]                // @Relationship
    var createdAt: Date
    var updatedAt: Date
}

@Model class Season {
    var number: Int
    var title: Title?              // inverse
    var episodes: [Episode]        // @Relationship cascade
}

@Model class Episode {
    var number: Int
    var seasonNumber: Int          // 冗余存一份便于查询
    var title: String?
    var airDate: Date?
    var overview: String?
    var season: Season?            // inverse
    var versions: [VersionFile]    // @Relationship cascade
}

@Model class VersionFile {
    var fileURL: URL               // 安全作用域 bookmark 另存
    var bookmark: Data?
    var fileSizeBytes: Int64
    var fileFingerprint: String    // inode + size，去重用
    var resolution: String?
    var releaseGroup: String?
    var languages: [String]        // 字幕语言
    var isMissing: Bool            // 文件不在了
    var episode: Episode?          // inverse；电影时 episode 为占位 season0/ep0
}

@Model class Tag {
    var name: String
    var category: TagCategory      // .genre/.year/.country/.ratingBucket/.quality/.releaseGroup/.userDefined
}

@Model class WatchProgress {
    var titleId: PersistentIdentifier
    var seasonNumber: Int?
    var episodeNumber: Int?
    var lastPositionSec: TimeInterval
    var durationSec: TimeInterval
    var state: ProgressState       // .unseen / .inProgress / .completed
    var updatedAt: Date
}

@Model class MetadataCache {
    var cacheKey: String           // "<providerId>|<externalId>|<locale>"
    var payload: Data              // 编码后的 MetadataDetails
    var fetchedAt: Date
}
```

枚举：`MediaKind` / `MatchState` / `TagCategory` / `ProgressState`。

> 进度与版本解耦：`WatchProgress` 以 `(titleId, seasonNumber, episodeNumber)` 为键，不绑 VersionFile，从而实现 US-20"集级进度跨版本共享"。

### IM-5 · 扫描器

- 视频扩展名白名单：`mkv mp4 m4v mov avi ts flv webm wmv rmvb`。
- 全量扫描：`actor LibraryService` 内用 `FileManager.enumerator`，分批 yield；进度通过 `AsyncStream` 上报 UI。
- 增量：FSEvents（`FSEventStreamCreate`）监听 scan roots，500ms 防抖，事件折叠为受影响目录集合后做局部扫描。
- 去重指纹：`fileFingerprint = "<st_dev>:<st_ino>:<fileSize>"`；命中既有 VersionFile 则更新而非新建。
- 缺失处理：扫描时若既有 VersionFile 的文件不存在 → 标 `isMissing = true`，不删（保留观看进度与历史）。

### IM-6 · 元数据查询编排

详见 ADR-0005。`actor MetadataService`：

- `ProviderRegistry`：按 `ParsedMedia.kind` 决定查询顺序（番剧 → bangumi 主 + tmdb-tv 次；剧集 → tmdb-tv；电影 → tmdb-movie；豆瓣若启用则并查补中文）。
- 并发：`async let` 同时打多个 provider，单 provider 超时 3s、总超时 5s。
- 每个 provider 内部 rate limit + `MetadataCache` 优先。
- 失败隔离：某 provider throw → 记录并跳过，不影响其它源合并。

### IM-7 · 匹配相似度与分流

`SimilarityScorer`（ADR-0005）：标题 Levenshtein 归一化（0–1）× 0.6 + 年份匹配（±1 年满分）× 0.25 + 季集存在且一致 × 0.15。分流阈值：

- `score ≥ 0.85` → `matchState = .confirmed`，自动入库。
- `0.65 ≤ score < 0.85` → `matchState = .pendingConfirmation`，入库但标待确认。
- `score < 0.65` → `matchState = .unmatched`，进待确认队列；VersionFile 仍入库挂在一个 placeholder Title（kind=.unknown）下，保证文件可见可播。

### IM-8 · 档案页跳播（iina 集成）

复用 Phase 1 的 `IinaBridge`（`openForPlayback(url:)`）。Library 不直接依赖 iina target；通过 `IinaBridgeRegistry` 拿到桥实例打开 VersionFile。播放进度回写见 IM-9。

### IM-9 · 播放进度回写（hook 点）

Phase 1 `IinaBridge` 已有 `currentVideoPositionSec()`。Phase 2 扩展桥协议，增加：

- `IinaBridge.observePlaybackProgress(handler:)` —— iina 侧在播放位置变化 / 文件结束时回调 `(url, positionSec, durationSec)`。
- iina 侧 hook：`iina/IinaMagnetBridge.swift` 监听 `PlayerCore.active` 的 time-pos / EOF（沿用 Phase 1 同一文件，加 `// MARK: iina-magnet hook`）。
- `WatchProgressTracker`（actor）把回调按 `(title, season, episode)` 归一，写 `WatchProgress`，≥90% 置 `.completed`。

### IM-10 · Library 菜单启用

Phase 1 在 `Bootstrap.swift` 把 "Library…" 菜单项设为 `isEnabled = false`。Phase 2 启用它，`MagnetMenuActions.showLibrary` 打开 `LibraryBrowserView` 窗口（`WindowFactory` `.library` key）。

### IM-11 · API key 与隐私

- 不内置任何 provider API key。TMDB / Bangumi key 由用户在 Settings 填写；缺 key 时对应源静默跳过并在 banner 提示。
- 豆瓣默认关闭（爬虫，反爬风险）；用户主动启用。
- 元数据请求只发往对应 provider 官方域名；不经任何自建中转。

## Testing Decisions

### TD-1 · 测试范围

| 模块 | 单元测试 | 集成测试 | UI 测试 |
| --- | --- | --- | --- |
| `FilenameParser`（含 Anitomy 映射 + regex fallback） | ✅ 必须 | — | — |
| `MetadataMerger` | ✅ 必须（100% 行） | — | — |
| `SimilarityScorer` | ✅ 必须 | — | — |
| `TagDeriver` | ✅ 必须 | — | — |
| `AnitomyBridge` | ✅（Obj-C++ 解析样例） | — | — |
| 各 `MetadataProvider` | ✅（fixture JSON，不联网） | — | — |
| `LibraryService` Scanner / Ingester | ✅（临时目录 + 假文件树） | ✅（端到端：假文件树→入库断言） | — |
| `WatchProgressTracker` | ✅（假回调序列） | — | — |
| `MetadataService` 编排 | ✅（假 provider，验证超时 / 失败隔离） | — | — |
| Library / 档案页 UI | — | — | 不强制 |

### TD-2 · 好测试的定义

只测可观察行为。例（好）：

```
// 给定文件名 "[Nekomoe kissaten][Boku no Hero Academia][01][1080p][CHS].mkv"
// 当 FilenameParser.parse
// 那么 title=="Boku no Hero Academia" && episode==1 && resolution=="1080p"
```

例（坏）：验证内部调用了 Anitomy 而非 regex。

### TD-3 · 集成测试基础设施

- `Tests/fixtures/filenames/` —— 真实番剧 / 美剧 / 电影文件名样本（覆盖 Anitomy 命中与 fallback 两类），每条带期望解析结果。
- `Tests/fixtures/metadata/` —— TMDB / Bangumi / Anilist / 豆瓣 的真实响应 JSON / HTML 样本（去敏感、去 key），供 provider 单测。
- `Tests/fixtures/filetree/` —— 在临时目录程序化构造假视频文件树（空文件 + 指定名/大小），供 Scanner / Ingester 集成测试。
- 网络隔离：所有 provider / scanner 测试禁止访问外网。

### TD-4 · 性能验收

- 5000 文件全量扫描（仅文件遍历 + 解析，不含联网元数据） < 60s。
- 增量扫描（单目录 ~50 文件变更）端到端 < 2s。
- `FilenameParser.parse` 1000 次 < 100ms（性能 gate，参考 Phase 1 perf target 写法）。
- `MetadataMerger.merge` 1000 次 < 50ms。
- Library 总览首屏（1000 作品海报墙，懒加载缩略图）滚动不掉帧。

### TD-5 · CI

沿用 Phase 1：PR 跑单元 + 关键集成；upstream merge / develop 合并跑全套 + Release 构建。新增 perf target case 进 PerformanceTests。

---

## Out of Scope

Phase 2 **明确不做**：

- 在线字幕搜索 / Whisper 字幕生成（→ Phase 3+）
- 多设备同步 / CloudKit（→ Phase 3+）
- 推荐 / 相似作品 / 热门榜（→ Phase 3+）
- 自动质量升级（自动用更高清晰度替换低清晰度版本）
- 弹幕 / 评论
- 自建元数据聚合 backend（ADR-0005 已否决）
- iOS / iPadOS
- 媒体库内的转码 / 压制
- 多用户 / 权限隔离

后续如需，写新 PRD + grill-with-docs。

---

## Further Notes

### 与 Phase 1 的衔接

- Phase 1 "下载完成路径" 首启动 Phase 2 时自动注册为 scan root（US-34）。
- Phase 1 的 `IinaBridge` / `IinaBridgeRegistry` 直接复用，不重写。
- 字幕已由 Phase 1 `SubtitleExtractor` 落到 sidecar；Phase 2 扫描只关心视频文件，字幕由 mpv 自动加载，不重复处理。

### 升级与迁移

Phase 1 → Phase 2 是 schema 增量（新增 Title 等表，旧表不动）。SwiftData lightweight migration 即可。无破坏性变更。

### Phase 2 → Phase 3+ 衔接

- `MetadataProvider` 协议预留，便于 Phase 3+ 加在线字幕 / 更多源。
- `WatchProgress` 结构与同步无关，Phase 3+ 加 CloudKit 同步时以它为同步单元。

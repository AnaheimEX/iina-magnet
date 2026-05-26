# PRD · Phase 1：BT/RSS 订阅 + 边看边播

Status: ready-for-agent
Phase: 1
Created: 2026-05-26
Owner: iina-magnet maintainers
Target Release: v0.1.0-phase1
Estimated Effort: 6-8 weeks

> 本文档使用 [mattpocock/skills](https://github.com/mattpocock/skills) `/to-prd` 模板。Phase 1 完成后归档不再修改；调整通过新 PR 与新 ADR 协作。

---

## Problem Statement

我作为一个 macOS 上的资源用户：

- 我订阅了若干 BT 资源站（mikanani.me、nyaa.si、动漫花园 …）的 RSS。当前流程：用一个 RSS reader 看通知 → 复制磁链 → 粘到 Transmission/qBittorrent → 等下完 → 打开 iina 播放 → 找字幕 → 拖到播放器。
- 这个流程被切成 4 个 app（RSS reader / BT 客户端 / 字幕工具 / 播放器），上下文割裂。
- 我希望"看到一个想看的，订阅一下，自动下载，自动配字幕，自动开始播放"，最好下载没完就能开始看。
- 此外当前 BT 客户端的"RSS 自动下载规则"非常原始，关键词匹配粗糙，重复下载常发生。

## Solution

在 iina-magnet 里新增"Magnet"功能区，含两个独立 SwiftUI 窗口：

1. **RSS Manager** —— 管理订阅源、规则、Feed 历史、命中记录
2. **BT Manager** —— 管理 torrent 任务、查看下载进度、控制下载

订阅流程：

```
用户在 RSS Manager 添加订阅源（URL + 可选 cookie/header + 轮询区间）
  ↓
用户为该订阅源创建若干规则（include[]/exclude[]/regex）
  ↓
后台 Scheduler 按区间拉取 → 解析 → 规则匹配
  ↓
命中条目自动添加到 TorrentManager（libtorrent）
  ↓
libtorrent 顺序下载 + sparse 写入
  ↓
用户在 BT Manager 双击任务 → iina 主窗口播放
  ↓
mpv 边读 sparse file 边播；StreamPlanner 维护 piece deadline 窗口
  ↓
下载完成后 SubtitleExtractor 复制字幕到视频 sidecar 路径
  ↓
（可选）下载完成后整体移动到用户配置的"下载完成路径"
```

---

## User Stories

### 订阅源管理（US-1xx）

1. 作为用户，我想添加一个 RSS 订阅源（URL + 显示名 + 可选 cookie/header），以便 app 定期拉取该源的更新。
2. 作为用户，我想为某个订阅源配置自定义 HTTP header（包括 Cookie），以便订阅需要登录态的源（如 mikanani.me 的 MyBangumi）。
3. 作为用户，我想为每个订阅源单独设置轮询区间（15min / 30min / 1h / 3h / 6h / 12h），以便平衡时效与服务器压力。
4. 作为用户，我想禁用某个订阅源（保留配置），以便在不删除规则的情况下临时停拉。
5. 作为用户，我想删除某个订阅源（连同其规则与历史），以便清理过期源。
6. 作为用户，我想在 RSS Manager 中预览订阅源的最新 N 条 Feed 原始记录，以便确认 URL 拉取正常并设计规则。
7. 作为用户，我想看到每个订阅源的"上次拉取时间 / 上次拉取结果（成功 / 错误 + 错误信息）"，以便排查问题。
8. 作为用户，我想手动触发某个订阅源立即拉取一次，以便测试新规则。

### 规则与匹配（US-2xx）

9. 作为用户，我想为一个订阅源创建一条规则，包含 `include[]`（必须命中的关键词）与 `exclude[]`（任一命中即否决的关键词），以便筛选我想要的资源。
10. 作为用户，我希望关键词匹配默认是大小写不敏感的 substring，以便不用纠结大小写。
11. 作为用户，我希望可以为单条规则启用高级正则模式（一条 regex 替代 include 列表），以便表达"S01E0[1-5]"这类复杂模式。
12. 作为用户，我希望规则有"启用/禁用"开关，以便临时停用某条规则而不删除。
13. 作为用户，我希望每条规则有一个显示名（用户填写），以便在命中历史里识别哪条规则命中了。
14. 作为用户，我希望规则编辑时能立即用当前订阅源的最新 Feed 试匹配（实时显示命中条数 + 命中条目预览），以便不用等下次拉取就知道效果。
15. 作为用户，我希望相同 Feed 条目（同 guid 或同 enclosure URL）不会被重复匹配下载，以便防止网站 RSS bug 或我自己改规则导致的重复任务。
16. 作为用户，我希望可以看到"命中历史"，列出曾经被哪条规则命中、命中时间、对应 torrent 任务状态，以便回溯。

### BT 下载（US-3xx）

17. 作为用户，我想在 BT Manager 看到所有 torrent 任务列表，含：名称、状态（解析中 / 下载中 / 已暂停 / 已完成 / 失败）、进度、当前速度、连接 peer 数、ETA。
18. 作为用户，我想暂停 / 恢复 / 删除某个任务。
19. 作为用户，我想删除任务时选择 "是否同时删除已下载文件"。
20. 作为用户，我想手动添加 magnet 链接 / `.torrent` 文件（拖拽或粘贴）以触发下载，以便那些不通过 RSS 来的资源。
21. 作为用户，我想看到全局上传/下载速度，以便快速判断是否影响其它网络应用。
22. 作为用户，我希望"零做种"是默认行为（下完即停止上传），但允许我在 Settings 全局或单任务覆盖。
23. 作为用户，我希望应用退出时下载任务能保存状态并在下次启动恢复。
24. 作为用户，我希望存储路径默认在 `~/Library/Application Support/iina-magnet/cache/`，可以在 Settings 修改。
25. 作为用户，我希望任务下载完成后自动把所有产物（视频 + 字幕 + 元数据）移动到我设置的"下载完成路径"（按 torrent 名命名子目录），原 cache 目录被清空。
26. 作为用户，我希望可以选择"原位保留"（不移动），以便我自己整理。

### 边看边播（US-4xx）

27. 作为用户，我想在 BT Manager 双击某个未下完的任务时，直接打开主视频文件在 iina 主窗口播放，即使任务仅下载了开头部分。
28. 作为用户，我希望播放过程中 mpv 缓冲不足时能等待 piece 完成而不是报错退出（理想情况：1-3 秒内自动续播）。
29. 作为用户，我希望在播放中往后 seek 时，BT 引擎能立刻把 seek 目标附近的 piece 提到最高优先级。
30. 作为用户，我希望可以在 BT Manager 任务详情里看到当前哪些 piece 已经下载（简单进度条 + 关键文件块状态）。
31. 作为用户，如果一个 torrent 含多个视频文件（合集 / 一季番剧），我希望能选择播放其中一个文件。
32. 作为用户，如果 torrent 中有多个视频文件且按命名规律是"第 NN 集"，我希望应用能识别出集数顺序（用 Anitomy + 自研 regex），并在播放列表里有序展示。

### 字幕外挂（US-5xx）

33. 作为用户，我希望 torrent 下载完成后，应用自动识别其中的字幕文件（`.srt` / `.ass` / `.ssa` / `.vtt` / `.sub`+`.idx` / `.sup`），并复制到对应视频的同目录同基名，以便 mpv 自动加载。
34. 作为用户，如果一个视频对应多种语言字幕（如 "Movie.S01E01.sc.srt"、"Movie.S01E01.tc.srt"、"Movie.S01E01.jp.srt"），我希望全部都被复制到 sidecar，mpv 字幕菜单能列出。
35. 作为用户，如果字幕在子目录（如 `Subs/01/sc.ass`），我希望应用能找到并复制到主视频同目录（同时保留语言 / 编号信息在文件名中）。
36. 作为用户，我希望即使字幕文件还没下完，主视频也能播放（字幕是次要的，不阻塞）。
37. 作为用户，我希望已经下载完成但不在 sidecar 路径的字幕能在用户主动点击 "重新提取字幕" 时被处理。

### 法律 / 启动流程（US-6xx）

38. 作为用户，首次启动 iina-magnet 时我希望看到清晰的 Disclaimer 弹窗（zh-Hans + en 双语），明确告知本项目仅提供技术能力，下载内容的合法性由我自行负责。
39. 作为用户，在 Disclaimer 弹窗里我必须点击 "我已阅读并同意" 才能继续，且应用记录我的同意时间。
40. 作为用户，我希望在 Settings 里随时能再次查看 Disclaimer 全文。
41. 作为用户，我希望 BT / RSS 功能默认不预置任何 tracker URL（包括 ipv4/ipv6 tracker 列表），以免被误解为内置违法资源指引。

### Settings（US-7xx）

42. 作为用户，我想在 Settings 配置：默认 cache 路径、下载完成路径、并发 torrent 上限、默认做种策略、做种比例上限、磁盘空间预警阈值。
43. 作为用户，我想在 Settings 配置全局 BT 网络参数：监听端口、是否启用 DHT、是否启用 PEX、是否启用 LSD、UPnP 是否启用、加密强制 / 优先 / 关闭。
44. 作为用户，我希望默认不启用 UPnP（避免误改路由器配置），由我主动启用。

### 可观测性（US-8xx）

45. 作为用户，我希望在 RSS Manager 看到"调度器队列下次执行时间"以及最近 N 次拉取的耗时 / 成功率，以便判断订阅是否健康。
46. 作为用户，遇到错误时（订阅源返回 403、torrent 解析失败、Disk full 等）我希望在对应窗口看到 banner 提示，且能点击 "查看详细日志"。
47. 作为开发者 / 高级用户，我希望调试 build 提供"导出 RuleEngine 输入 + 输出"功能，以便提交 issue 时附数据。

---

## Implementation Decisions

> 不包含具体文件路径与代码片段（除非该片段精确编码了决策）。文件路径在实现 issue 中描述。

### IM-1 · 新模块的目录与目标布局

- 新代码全部放 `iina-magnet/` 顶层目录。该目录是一个独立的 Swift package / Xcode target，被 iina 主 target 引用。
- iina 原代码（`iina/` 目录）只允许在 hook 点修改（[CLAUDE.md](../../CLAUDE.md) "工作约束"）。

### IM-2 · 核心深模块

以下 4 个模块是深模块（小接口 / 大功能 / 可测试 / 稳定），必须单测覆盖：

1. **`RssRuleEngine`** —— 纯函数 `evaluate(items: [FeedItem], rules: [Rule]) -> [Match]`
2. **`AnitomyParser`** —— 包装 Anitomy 库，纯函数 `parse(filename: String) -> AnimeFields?`
3. **`TorrentManager.StreamPlanner`** —— 纯函数 `plan(playerOffset: Double, totalDuration: Double, pieceMap: PieceMap) -> [PieceDeadline]`
4. **`SubtitleExtractor`** —— 纯函数 `extract(rootDir: URL) -> [(video: URL, subs: [URL])]`

剩余模块是组合层（actor 调度 / IO / UI），不要求 100% 单测，但要有集成测试覆盖关键路径。

### IM-3 · libtorrent 桥接

详见 [ADR-0002](../adr/0002-libtorrent-inproc.md)。

`LibtorrentBridge.mm` 公开接口（伪签名）：

```objc
@interface LMSession : NSObject
- (instancetype)initWithSettings:(LMSessionSettings *)settings;
- (NSString *)addMagnet:(NSString *)magnetURI savePath:(NSString *)path;
- (NSString *)addTorrentFile:(NSData *)torrentData savePath:(NSString *)path;
- (void)pauseTorrent:(NSString *)infoHash;
- (void)resumeTorrent:(NSString *)infoHash;
- (void)removeTorrent:(NSString *)infoHash deleteFiles:(BOOL)deleteFiles;
- (void)setPieceDeadline:(NSString *)infoHash piece:(int)piece deadlineMs:(int)ms;
- (LMTorrentStatus *)statusOf:(NSString *)infoHash;
- (NSArray<LMAlert *> *)pumpAlerts;
@end
```

### IM-4 · RSS 数据模型

```swift
@Model class SubscriptionSource {
    var url: URL
    var displayName: String
    var pollInterval: TimeInterval
    var cookieHeader: String?
    var customHeaders: [String: String]
    var enabled: Bool
    var rules: [SubscriptionRule]
    var lastPolledAt: Date?
    var lastPollResult: PollResult?  // .success / .error(msg)
}

@Model class SubscriptionRule {
    var name: String
    var include: [String]
    var exclude: [String]
    var regex: String?          // nil = 不用正则
    var caseSensitive: Bool     // 默认 false
    var enabled: Bool
    var hitCount: Int           // 累计命中数
}

@Model class FeedItem {
    var guid: String            // RSS <guid> 或 URL hash
    var title: String
    var enclosureURL: URL
    var publishedAt: Date
    var sourceId: PersistentIdentifier
    var matched: Bool           // 是否已被某规则命中
    var matchedRuleId: PersistentIdentifier?
    var firstSeenAt: Date
}
```

### IM-5 · 规则匹配算法

输入：一条 `FeedItem`、若干 `SubscriptionRule`（按 enabled 过滤）。

每条规则的判定（一条规则的 `include` / `exclude` / `regex` 中：`regex` 优先）：

```
if rule.regex != nil:
    match = regex.matches(item.title)
else:
    match = (include.isEmpty || include.all { kw in title.contains(kw) })
            && exclude.none { kw in title.contains(kw) }

if match: produce Match(item, rule)
```

一个 item 可被多条规则同时命中（但只发起一次下载——以最早 enabled 规则为准）。

### IM-6 · BT 边看边播算法

详见 [ADR-0002 实施约定](../adr/0002-libtorrent-inproc.md)。

`StreamPlanner.plan(playerOffset, totalDuration, pieceMap)`：

```
totalPieces = pieceMap.count
playerPiece = floor(playerOffset / pieceMap.pieceLength * fileSizeNormalized)

return pieces where idx in [playerPiece, playerPiece + 30s_pieces]
       deadline = 0ms

return pieces where idx in [next, +60s_pieces]
       deadline = 1000ms

return pieces where idx in [next, +120s_pieces]
       deadline = 5000ms

return其他: 不设 deadline（libtorrent 默认调度）
```

每秒 / 每次 seek 重算一次。

### IM-7 · 字幕外挂识别

支持扩展名：`.srt`, `.ass`, `.ssa`, `.vtt`, `.sub`+`.idx`（双文件）, `.sup`（蓝光 PGS）

算法：

```
对 torrent 完成区域内每个文件 f：
    若 f 是字幕文件：
        找最接近的视频文件 v（同目录最近邻 / 同基名 / 共享集数序号）
        复制 f 到 dirname(v)/basename(v).<lang>.<ext>
            其中 <lang> 从原文件名启发式提取（sc/tc/jp/en/chs/cht 等）
```

启发式 `lang` 识别表：

| 文件名片段（小写包含） | lang code |
| --- | --- |
| `chs`, `sc`, `gb`, `简` | `zh-Hans` |
| `cht`, `tc`, `big5`, `繁` | `zh-Hant` |
| `jp`, `jpn`, `日` | `ja` |
| `en`, `eng`, `english` | `en` |
| `kr`, `kor`, `韩` | `ko` |
| 无法识别 | `und`（mpv 自动当 default） |

### IM-8 · Disclaimer 流程

- `DisclaimerAcceptance` 表存版本 + 接受时间
- 启动时检查当前 disclaimer 版本（硬编码 const）vs 已接受版本
  - 未接受 → 弹模态窗口（zh-Hans + en 双语显示，用户系统语言决定哪个是默认 tab）
  - 已接受 → 直接进主界面
- Disclaimer 文本独立文件 `Resources/Disclaimer.zh-Hans.md` + `Disclaimer.en.md`
- Disclaimer 更新（重大法律变更）→ 升 version → 用户重看一次

### IM-9 · iina 集成（hook 点）

仅修改以下 iina 原文件：

1. `iina/AppDelegate.swift`：
   - `applicationDidFinishLaunching` 末尾调 `IinaMagnetBootstrap.start()`
   - `applicationWillTerminate` 调 `IinaMagnetBootstrap.shutdown()`
2. `iina/Resources/MainMenu.xib`（或 SwiftUI Menu）：
   - 增加 "Magnet" 顶层菜单 + 子菜单 item

每处加 `// MARK: iina-magnet hook` 注释。

### IM-10 · Settings 集成

iina 的 Settings 是 AppKit `NSWindowController`。我们**不嵌入**——通过 hook 在 iina 主菜单加 "Magnet > Settings…"，打开独立 SwiftUI 窗口。

## Testing Decisions

### TD-1 · 测试范围

| 模块 | 单元测试 | 集成测试 | UI 测试 |
| --- | --- | --- | --- |
| `RssRuleEngine` | ✅ 必须 | — | — |
| `AnitomyParser` | ✅ 必须 | — | — |
| `SubtitleExtractor` | ✅ 必须 | — | — |
| `StreamPlanner` | ✅ 必须 | — | — |
| `RssService` (含 Fetcher / Parser) | 单元（Parser 部分） | ✅（HTTPMock + RSS 固定 fixture） | — |
| `TorrentManager` (libtorrent wrapper) | — | ✅（用 .torrent fixture + 自建本地 tracker） | — |
| `SubscriptionScheduler` | ✅（用假时钟） | — | — |
| Disclaimer 流程 | — | ✅ | 可选 |
| RSS Manager / BT Manager UI | — | — | 不强制 |

### TD-2 · 好测试的定义

**只测可观察行为，不测实现细节。**

例子（好）：
```
// 给定一条带有 include=["1080p"], exclude=["RAW"] 的规则
// 当 evaluate 一个 title="[Group] Show S01E01 1080p RAW.mkv" 的 item
// 那么 它不应该命中
```

例子（坏）：
```
// 验证 evaluate 内部使用了 trie 索引
// 验证 RssRuleEngine 调用 String.lowercased 一次
```

### TD-3 · 集成测试基础设施

- `tests/fixtures/rss/` —— 真实 mikanani / nyaa / 动漫花园 抓取的 RSS XML 样本（去敏感信息）
- `tests/fixtures/torrents/` —— 公开 license 的 ubuntu / Debian iso .torrent 文件（用于 libtorrent wrapper 测试）
- `tests/integration/LocalTrackerServer` —— 本地起一个 minimal BT tracker（HTTP），供 wrapper 测试
- 网络隔离：集成测试**禁止访问外网**；任何外部调用必须 mock 或 fixture

### TD-4 · CI 必跑

- `swift test --target IinaMagnetTests` 单元测试
- `swift test --target IinaMagnetIntegrationTests` 集成测试
- `xcodebuild -scheme iina-magnet -configuration Release` 构建产物
- Upstream merge commit 必须跑全套；其他 PR 必须跑单元 + 至少 1 个集成测试

### TD-5 · 类似 prior art

无（项目从 0 起）。但可以参考：
- libtorrent 自带 examples / unit test pattern
- iina 现有的 `iina/Tests/` Swift Test 风格（XCTest，但建议新模块用 Swift Testing `@Test` 宏）

---

## Out of Scope

Phase 1 **明确不做**：

- 媒体库 / 元数据 / 档案页（→ Phase 2）
- 自动质量升级（自动用更高质量替换已下载的较低质量）
- 在线字幕搜索 / Whisper 字幕生成（→ Phase 3+）
- 多设备同步（→ Phase 3+）
- iOS / iPadOS 支持
- 自建 RSS 抓取 backend / 自建 tracker / 自建索引
- DLNA / AirPlay 投屏（iina 原生已有）
- 弹幕集成
- 商业化 / 付费功能

如果某项后续要做，需要新的 PRD 与 grill-with-docs 流程。

---

## Further Notes

### 性能预期（验收目标）

- 同时 10 个 torrent，总下行 ≥ 20MB/s 时 mpv 不卡顿（< 3% frame drop）
- libtorrent piece 完成 → mpv 可见时间 < 500ms
- RSS 规则评估 1000 条 FeedItem × 50 条 Rule < 50ms（单线程）
- 启动到 RSS Manager 可交互 < 1.5s

### 用户文档

Phase 1 release 前补：

- `README.md` 新增"如何添加订阅源"段落（含 mikanani.me cookie 获取示例）
- `README.md` 新增"如何写规则"段落（含常用关键词模板）
- `README.md` 法律免责段落

### 升级与迁移

Phase 1 是首版，无升级路径。

### Phase 1 → Phase 2 衔接

Phase 1 完成后，下载完成的 torrent 文件落在用户配置的"下载完成路径"。Phase 2 启动时该路径自动加入 scan roots，全量扫描后入库——确保 Phase 1 用户升级到 Phase 2 时所有历史下载自动出现在媒体库。

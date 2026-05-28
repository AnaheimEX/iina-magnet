# ADR-0006 · Anitomy 文件名解析桥接

Status: Accepted
Date: 2026-05-29
Related: [ADR-0002（libtorrent 进程内桥接）](./0002-libtorrent-inproc.md), [ADR-0005（多源元数据）](./0005-multi-source-metadata.md)

## Context

Phase 2 入库的第一步是把视频**文件名**解析成结构化字段（作品名 / 季 / 集 / 年份 / 清晰度 / 字幕组），再拿去查元数据。

资源文件名形态高度不规则，尤其番剧：

```
[Nekomoe kissaten][Boku no Hero Academia][01][1080p][CHS].mkv
【喵萌奶茶屋】★04月新番★[葬送的芙莉莲][01][1080p][简日双语].mkv
[LoliHouse] Frieren - 01 [WebRip 1080p HEVC-10bit AAC][CHS].mkv
Show.Name.S01E03.1080p.WEB-DL.x264.mkv
Movie.Name.2021.2160p.BluRay.x265.mkv
```

自己写正则覆盖所有番剧组的命名习惯成本极高且易漏。社区已有成熟方案 **[Anitomy](https://github.com/erengy/anitomy)**——一个 C++ 的动画文件名解析库，被 Sonarr/Shoko 等广泛使用，专门处理这类 `[组][名][集][规格]` 命名。

需求：
- 番剧命名解析质量要好（这是用户主场景，见 ADR-0005）。
- 非番剧（美剧 `SxxExx`、电影 `Name.Year`）命名也要能解析——但这部分 Anitomy 不专长。
- 解析必须是**纯函数、可单测、不依赖网络与文件系统**。
- 不能给 upstream merge 引入 ABI / 编译风险。

## Decision

**引入 Anitomy（C++）作为进程内静态依赖，用 Obj-C++ 桥接，Swift 侧包一层 `FilenameParser` 做"Anitomy 主 + 内置 regex 兜底"。**

与 ADR-0002（libtorrent）一致的模式：

1. Anitomy 源码 vendored 到 `lib/anitomy/`（它是 header + 少量 cpp 的小库，无 Boost 依赖），随项目编译，不引第三方包管理器。
2. 新建 SwiftPM target `AnitomyBridge`（Obj-C++ `.mm`），与 `LibtorrentBridge` 平级。仅暴露原生类型接口：

   ```objc
   @interface ANTParser : NSObject
   /// 返回 Anitomy element 名 → 值 的字典；解析空结果返回 nil。
   + (nullable NSDictionary<NSString *, id> *)parse:(NSString *)filename;
   @end
   ```

   字典 key 用 Anitomy 原生 element 名：`anime_title` / `episode_number` / `anime_season` / `anime_year` / `video_resolution` / `release_group` / `file_extension` 等。Anitomy 的 C++ 类型不外泄。

3. Swift 侧 `FilenameParser`（深模块，PRD §IM-2）：

   ```swift
   struct ParsedMedia: Sendable, Equatable {
       var title: String
       var season: Int?
       var episode: Int?
       var year: Int?
       var resolution: String?
       var releaseGroup: String?
       var kindHint: MediaKind   // .tv / .movie / .unknown 的推测
   }

   enum FilenameParser {
       static func parse(_ filename: String) -> ParsedMedia
   }
   ```

   流程：先调 `ANTParser.parse`。若拿到 `anime_title` 且有 `episode_number` → 映射为 `ParsedMedia(kind: .tv)`。否则走**内置 regex 兜底**：
   - `S(\d+)E(\d+)` → 季/集，剩余前缀作 title，kind=.tv
   - `[._ ](19|20)\d{2}[._ ]` 且无集号 → year + title，kind=.movie
   - 都不命中 → title=去扩展名的清洗文件名，kind=.unknown

## Alternatives Considered

### A. 纯自研正则，不引 Anitomy

零依赖、零桥接成本。但番剧命名变体太多（不同组的分隔符、季度标记、合集范围 `[01-12]`、多语言标签），自研 regex 长期维护成本高、召回差。Anitomy 已经把这块做透。**放弃**作为唯一方案，但**保留为 fallback**（处理 Anitomy 不擅长的美剧 / 电影）。

### B. 把 Anitomy 编进 LibtorrentBridge target

省一个 target。但两者职责无关（BT vs 文件名解析），混在一起会让 libtorrent 那个重型编译单元更难维护，也不利于单独为 Anitomy 写桥接测试。**放弃**，各自独立 target。

### C. 找一个纯 Swift 的解析库

避免 C++ 桥接。但现有纯 Swift 方案成熟度 / 召回远不及 Anitomy，且会再引一个 SwiftPM 远程依赖（项目原则是尽量 vendored、少远程依赖）。**放弃**。

### D. Anitomy 用动态库 / 远程 SwiftPM

ABI 与分发复杂度高，且 Anitomy 体量小，没必要。**放弃**，走 vendored 静态编译（同 ADR-0002）。

## Consequences

### 正面

- 番剧文件名解析质量直接达到社区成熟水平。
- 与 ADR-0002 同构的桥接模式，团队心智一致。
- `FilenameParser` 是纯函数深模块，100% 可单测（含 Anitomy 命中与 regex fallback 两条路径）。
- Anitomy 无 Boost / 无网络，编译开销远小于 libtorrent。

### 负面与缓解

| 负面 | 缓解 |
| --- | --- |
| 又一个 Obj-C++ 桥接编译单元 | Anitomy 是小库（header-only 风格），编译快；CI 已能跑 .mm |
| Anitomy 对非番剧（美剧/电影）召回一般 | Swift 侧 regex fallback 兜底；`kindHint` 标 .movie/.tv 走对应 provider |
| Anitomy upstream 已不活跃 | vendored 锁定版本，行为可预测；解析逻辑由我们的单测固定 |
| C++ 字符串 ↔ NSString 编码（中文 / emoji 标记） | 桥接层统一用 UTF-8；fixture 单测覆盖含中文 / 特殊符号的真实文件名 |

## 实施约定

- vendored 源码与编译脚本：`lib/anitomy/`（含 `build.sh` 若需预编译；优先随 SwiftPM target 直接编译源码）。
- `AnitomyBridge` target 的 module map 与头文件放 `iina-magnet/Sources/AnitomyBridge/include/`，与 `LibtorrentBridge` 布局一致。
- `FilenameParser` 必须有 fixture 驱动单测：`Tests/fixtures/filenames/` 每条 `{ filename, expected ParsedMedia }`，覆盖：番剧（多字幕组命名）、美剧 SxxExx、电影 Name.Year、合集范围、含中文标题、纯 unknown。
- `ANTParser.parse` 返回 nil（Anitomy 空结果）时，`FilenameParser` 必须仍返回一个 `.unknown` 的 `ParsedMedia`（title 为清洗后的文件名），保证任何文件都能入库可见可播。
- 性能：`FilenameParser.parse` 进 PerformanceTests（1000 次 < 100ms，PRD §TD-4）。

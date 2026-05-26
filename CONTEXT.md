# iina-magnet 领域词汇表

> 这是项目的共享语言。出现在 issue、PRD、提交、代码标识符与对话中的术语，都应在这里定义。
>
> 词条按出现的领域聚合。新词汇通过 `/grill-with-docs` 协议在解析时增量写入。

---

## 项目身份

### iina-magnet（寒骨）
本项目代号。"寒骨"取磁吸（magnet）入髓之意。区别于 [iina](https://github.com/iina/iina)（upstream）。在 fork 历史中作为不可逆品牌定位。

### upstream
特指 `iina/iina` 主仓库。`upstream sync` 表示从该仓库 merge 最新代码到本 fork。

### 寒骨模块（iina-magnet module）
fork 之上**新增的**代码区。位于 `iina-magnet/` 顶层目录。与 iina 原模块 `iina/` 平级，**只导入不修改**。

---

## 订阅域（Phase 1）

### 订阅源（Subscription Source）
一条用户配置的 RSS Feed。具有：URL、display name、轮询区间、可选 cookie/headers、enabled 开关。一个用户可有 N 个订阅源。

### Feed 条目（Feed Item）
RSS 解析后的单条记录，含标题、enclosure URL（torrent / magnet）、发布时间、可选 `<description>`。**与作品/集数无关**——作品识别由 Anitomy/元数据匹配做。

### 规则（Rule）
一条针对某个订阅源的匹配规则。模型：
- `include[]`：必须**全部命中**的关键词（substring，不区分大小写）
- `exclude[]`：任一命中即丢弃的关键词
- `regex`（可选）：高级模式，正则表达式（优先级最高，命中即过）

一个订阅源可有 N 条规则。`include[]=[]` 表示该规则不约束包含。

### 命中（Match）
Feed 条目通过某条规则的判定。命中的条目进入"待下载队列"。

### 待下载队列（Pending Download Queue）
经规则匹配但还未启动 libtorrent 任务的条目。用户可配置自动启动或手动确认。

### Torrent 任务（Torrent Task）
libtorrent 接管的下载任务。具有：infoHash、saveDir、状态（解析中 / 下载中 / 暂停 / 完成 / 失败 / 已删除）、进度、连接 peer 数。

### 边看边播（Stream-while-download）
通过 libtorrent `sequential_download = true` 与 `set_piece_deadline` 把所需 piece 优先取回，让 mpv 在文件未完整时就能播放。本项目核心能力。

### Sparse 缓存（Sparse Cache）
libtorrent 默认以 sparse file 写入磁盘——已下载的 piece 落盘到偏移位置，未下载部分是空洞（占名义大小但不占实际空间）。mpv 读到空洞时返回 EOF。

### Cache 目录（Cache Directory）
正在下载的 torrent 临时存放路径。默认 `~/Library/Application Support/iina-magnet/cache/`。下载完成后整体迁移到媒体库目标路径。

### 字幕外挂（External Subtitle Extraction）
从已下载 torrent 中识别 `.srt`/`.ass`/`.ssa`/`.vtt`/`.sub`+`.idx`/`.sup` 等字幕文件，复制到视频同目录同基名，让 mpv 自动加载。

---

## 媒体库域（Phase 2）

### 媒体库（Library）
用户的所有媒体作品集合。物理上是若干个用户配置的根路径（`scan roots`）。逻辑上是 SwiftData 数据库中的实体表。

### 作品（Title）
媒体库的顶层抽象。一部电影 / 一部剧集 / 一部番剧。通过 (provider, externalId) 唯一标识——主键是 `tmdbId`，缺省时 fallback 到 `bangumiId` / `anilistId`。

### 季（Season）
仅对剧集/番剧有意义。属于某个 Title，含 seasonNumber、episodes。

### 集（Episode）
"作品的一集"。属于某个 Season 或直接挂在 Title（单季作品）。具有 `episodeNumber`、可选标题、可选 air date。

### 版本（Version）
同一 Episode 的不同物理文件。区分维度：source、resolution、release group、language、container。**多版本不创建新档案页**——档案页列出所有版本供选择。

### 档案页（Archive Page）
作品的详情页面。Infuse / Apple TV App 风格：顶部 backdrop + 海报，下方 metadata（剧情、演职员、剧照），最后是集数网格，每集右上可选版本。

### 三态进度（Three-state Progress）
未观看 / 在看 / 已看。以**集级**为粒度：
- 未观看：该 episode 无任何文件被打开过
- 在看：至少一个文件被播放，但播放百分比 < 90%
- 已看：任一版本播放百分比 ≥ 90%（可设置）

进度按 `(titleId, seasonNumber, episodeNumber)` 主键，跨多版本合并。

### 媒体类型分类（Media Kind）
作品分为：`tv`、`movie`、`unknown`。
- `tv`：含至少一集且能识别 series → episode 结构
- `movie`：单文件、TMDB 匹配类型为 movie
- `unknown`：扫描失败 / 匹配失败 / 无元数据

`unknown` 不丢弃，进 "其他" 分类，等用户手动归属。

### 统计块（Stats Block）
媒体库底部的固定矩形区域，显示当前媒体库中的 tv / movie / unknown 计数。

### 扫描（Scan）
- 全量扫描（Full Scan）：用户手动触发；遍历所有 scan roots。
- 增量扫描（Incremental Scan）：FSEvents 监听到文件变化时触发的局部扫描。
- 入库扫描（Ingest Scan）：BT 任务下载完成后，对完成目录的针对性扫描，绕过 FSEvents 防抖。

### 元数据 Provider
能查询并返回作品元数据的外部服务。本项目接入 4 个：`tmdb`、`bangumi`、`anilist`、`douban`。

### 元数据合并器（MetadataMerger）
多 provider 同时命中时把结果合并为一条作品记录的逻辑。优先级与字段冲突规则在 `ADR-0005` 中定义。

### Provider 优先级
对中文片名 / 演职员中文名等字段，`douban` > `tmdb-zh` > `tmdb-en`。对番剧专属字段（声优、制作委员会），`bangumi` 优先。其他字段以 `tmdb` 为主源。

### Anitomy 解析
使用 Anitomy 库对动漫文件名进行解析，提取 `anime_title`、`episode_number`、`release_group`、`video_resolution` 等字段。是番剧文件 → 元数据匹配的第一道。

---

## 工程与协作

### Phase
项目阶段划分。Phase 1 = BT/RSS，Phase 2 = 媒体库，Phase 3+ 待定。

### 深模块（Deep Module）
Ousterhout 意义上的"小接口大功能"。本项目要求新增深模块（`RssRuleEngine`、`MetadataMerger`、`TorrentManager.pieceQueue`、`AnitomyParser` 包装）必须有单元测试。

### iina-magnet hook
对 iina 原文件的最小化修改点。所有 hook 必须以注释 `// MARK: iina-magnet hook` 标记，便于 upstream merge 时人工审视。

### Disclaimer（免责弹窗）
首次启动时强制显示的法律免责声明。zh-Hans + en 双语。用户必须明示同意才进入主界面。设置中可随时查看。

# 开发状态与后续补强记录

> 面向**继续开发**的工作笔记:当前状态、关键背景与决策、本阶段已完成的改动、
> 易踩的坑、以及尚未做的优化/功能补强清单。用户向的使用说明见
> [`README.iina-magnet.md`](../README.iina-magnet.md);跟进上游见
> [`UPSTREAM_SYNC.md`](./UPSTREAM_SYNC.md);SwiftData 模型见 [`schema.md`](./schema.md)。
>
> 最近更新:本阶段(提速 + 调优 + 修复)收尾,`develop` 全绿。

---

## 1. 当前状态快照

- 主分支:`develop`(每个单元走 `feature|fix|tune|chore/*` 分支 → 实现+测试 →
  `swift test` → 整 app 编译 → `--no-ff` 合回 → 推送)。
- 测试:**178 个 / 30 套件全绿**(`cd iina-magnet && swift test`)。
- 构建:整 app `BUILD SUCCEEDED`;调试产物在
  `/tmp/iina-dd/Build/Products/Debug/IINA.app`(`open` 即可)。
- `swift build` 零告警。SourceKit/编辑器偶有 “Cannot find X / Extra argument”
  **陈旧误报**,以 `swift build` / `swift test` 为准。

### 构建命令(务必照抄签名 flag)
```bash
PROJECT_NAME=iina-magnet ./other/download_libs.sh --skip-plugins   # 拉 mpv/dylib
xcodebuild -scheme iina -configuration Debug -derivedDataPath /tmp/iina-dd \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build              # 整 app
cd iina-magnet && swift test                                        # 库回归
```
> ⚠️ 必须用 `CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO`(不是
> `CODE_SIGNING_ALLOWED=NO`)。改写过 install name 的 dylib 若签名失效,macOS 26
> 会直接 SIGKILL。

---

## 2. 关键背景:真实使用流程(决定优先级)

**云端是「看完即弃」**:在蜜柑发现 → 存到 PikPak 离线 → 等 → 云播一次 → 不再
保留/重看。**本地媒体库只是偶尔用。**

由此确定的取舍(重要,避免重复走弯路):
- ❌ **不做**「云端文件入库 / 云播续播」——看完即弃,入库无意义(已永久砍掉)。
- ⏬ **降级** TMDB / 豆瓣 / 多源合并——只服务本地库,而本地库偶尔用;且 TMDB 需
  用户自备 API key、豆瓣公开 API 已废。
- ⭐ **重点**是让「发现 → 找文件 → 开播 → 首帧」这条一次性链路**快、稳、可清理**。

### 安全/凭据红线(必须保持)
PikPak 凭据**绝不进入开发环境**:用户在本机用自己账号登录,助手只写代码。登录走
**网页 token 抓取**(`PikPakLoginView` 加载 mypikpak.com,从 localStorage 取
Bearer token),密码不经过本项目代码;`PikPakAuth` 只记录 hash 过的 `sub`。
逆向 PikPak 私有 web API 仅用于用户访问**自己**的网盘(同 rclone/alist 性质)。

---

## 3. 本阶段已完成(均在 `develop`,带提交号)

| 主题 | 提交 | 摘要 |
| --- | --- | --- |
| captcha 静默重取 | `9aa44b4d` | code 9 且自签被拒时,离屏 WKWebView 重抓有效 captcha,再退回重新登录 |
| 移除 LibtorrentBridge | `a149c5dd` | 删除休眠的 BT target + vendored libtorrent(BT 已由 PikPak 替代) |
| 浏览器:缓存导航 + 盘内筛选 | `f5f93727` | 文件夹列表会话级缓存(返回瞬开)+ 即时筛选框 + 刷新 |
| 云播:取链预取 + 缓存 | `839082cb` | 悬停预取 + 5min 短缓存,点击→播放省一次往返 |
| 快起播 mpv 档 | `ee441b59` | 不预填缓存即起播 + 大幅缩短探测(probesize/analyzeduration),本地文件还原默认 |
| 蜜柑网页导航 | `56142069` | 后退/前进/刷新/主页 + 触控板手势 |
| 浏览器打磨 | `c419c1cb` | 记住排序 + 单击选中/双击播放 + ↑↓/回车键控 |
| 修:保存目录 + 云播慢 | `08564f1f` | findOrCreateFolder 不过滤 phase;保存后 `batchMove` 强制归位;云播等流媒体链 |
| 修:保存名 + 代理吞吐 | `4d6f8302` | 先曾改传空名;mpv `stream-lavf-o` 长连接/重连(过 Surge 代理省握手) |
| 修:蜜柑保存名 + 页面缩放 | `86e885bd` | `titleFor` 读同行 `a.magnet-link-wrap` 真实剧集名;蜜柑页脱离 scaleEffect、用自适应 `pageZoom` |
| 调优:刷新合并 + 预取去抖 | `7f476b52` | token 刷新合并(防掉登录);悬停预取去抖(~300ms)+ 按 id 去重 |
| 收尾:缓存上限 + 告警 | `508b68b5` | `PikPakListingCache` FIFO 上限 40;播放链缓存过期清扫;清 `try?` 告警 |

---

## 4. 架构关键点 / 易踩的坑

- **几乎所有自定义代码在独立 SPM 包 [`iina-magnet/`](../iina-magnet)**
  (`IinaMagnet` 库)。iina 侧只有少量 `// MARK: iina-magnet hook`:
  `iina/IinaMagnetBridge.swift`、`iina/AppDelegate.swift`、
  `iina/InitialWindowController.swift`。冲突面小,跟上游主要照顾这几处。
- **PikPak 私有 API**:auth 在 `user.mypikpak.net`,drive 在
  `api-drive.mypikpak.net`。错误码:16/4121/4122=access token 过期→刷新;
  9=captcha 过期→自签/重抓;10=限流。captcha 盐若轮换、登录失败,改
  `PikPakConfig.swift` 的 `web` 块(参考 alist/OpenList `drivers/pikpak`)。
- **PikPak 不一定认离线任务的 `parent_id`**:文件可能落到网盘根目录。所以
  `offlineDownload` 在建任务后用 `moveFiles`(`files:batchMove`)**强制把文件移进
  Pack From Shared**。`findOrCreateFolder` 用 `list(onlyCompleted:false)` 找文件夹
  (否则 phase 过滤可能漏掉已存在的文件夹 → 反复新建重复文件夹)。
- **蜜柑 DOM**(已抓真实页面核实):列表**不是 `<table>`**。每条 =
  `<a class="magnet-link-wrap" href="/Home/Episode/{hash}">{剧集标题}</a>`
  + 兄弟 `<a class="js-magnet" data-clipboard-text="magnet:?xt=...">`(**磁力无
  `dn`**)+ `<a href="/Download/{date}/{hash}.torrent">`。主页只有番剧链接、无种子。
  → `titleFor` 必须从点击的磁力/种子按钮**向上找同行 `a.magnet-link-wrap`** 取剧集
  名;磁力无 `dn`,所以保存名用抓到的剧集标题传给 `offlineDownload`。
- **快/慢播放链**:完成的文件有 `medias` 流媒体链(快、可 seek);刚下完的文件只有
  `web_content_link`(原始下载链、慢)。`bestPlaybackURL = streamingURL ??
  web_content_link`;蜜柑"保存并云播"用 `waitForStreamablePlaybackURL` 等流媒体链
  就绪(超时才退回原始链)。
- **token 刷新是 actor 重入点**:`PikPakAuth` 虽是 actor,但刷新在网络 `await`
  处会重入。并发 drive 调用必须**合并到单个 `refreshTask`**,否则各自用同一个
  会轮换的 refresh_token → 第二次失效 → 掉登录。改这块务必保持合并语义。
- **媒体库窗口统一缩放**:`LibraryWindowView` 用 GeometryReader + `scaleEffect`
  把内容放大(开窗时按屏幕算 `scale`)。**WKWebView 不能这样放**(会被缩小再放大
  → 内容裁切+发虚),所以**蜜柑页脱离该缩放、改用 `WKWebView.pageZoom`**
  (`mikanZoom = min(max(scale*0.8,1),1.5)`)。
- **进度跟踪只认本地文件**:`iina/IinaMagnetBridge.sampleProgress()` 守
  `url.isFileURL`,云播不记进度(符合 watch-once,刻意不做)。
- **PikPakDrive 是 `static let shared` actor**,跨浏览器/蜜柑/任务中心共享其缓存
  (playbackURLCache、prefetchingIDs、cachedOfflineFolderID)。

---

## 5. 优化审计:已做 / 未做

已做(本阶段):#1 刷新合并、#2 预取去抖+去重、#5 会话缓存上限、#7 编译告警。

未做(对 watch-once 价值低或成本高,按需再动):
- **#3 离线 `batchMove` 条件化** —— 想"已在目标文件夹就不移",但离线返回里拿不到
  文件 parent,要额外请求,得不偿失 → 暂跳过。
- **#4 海报图片管线** —— `CachedAsyncImage` 在**主线程解码**且**不降采样**,
  `NSCache` 只设了 `countLimit=400` 无 `totalCostLimit`。是全项目最大的渲染/内存
  优化(改用 ImageIO 后台缩略图 + 按字节 cost),但**只在本地库滚动海报墙时有感**,
  用户偶尔用 → 押后。
- **#6 进度采样 5s Timer** —— iina 侧常驻,CPU 极小,可空闲时暂停。
- **#8 `scaleEffect` 文字发虚** —— 高倍率下略软;真·尺寸缩放需改大量硬编码字号,
  大重构,可选。

---

## 6. 功能补强 backlog(尚未做,供点单)

贴合 watch-once 闭环、自给自足、可测:
- **A · 蜜柑「已存过」角标** —— 本地存"已存 magnet 的 btih"集合,注入 JS 给蜜柑
  命中行加角标,避免重复保存。磁力里有 `xt=urn:btih:{hash}`。无需新权限。
- **B · 离线下载完成通知** —— 任务完成弹系统通知(可点击直接云播),填"保存→等待"
  空档。需一次 `UNUserNotificationCenter` 授权。
- **C · 看完即删 / 网盘清理** —— PikPak 浏览器目前**只能浏览播放、不能删文件**
  (只有 `deleteTask` 删离线任务)。补 `batchTrash`/`files:batchTrash` + 浏览器删除
  动作 + 可选"播完提示删除"。watch-once 防网盘堆满。

较大/把握略低(列出供参考):
- **D · PikPak 全盘搜索**(跨文件夹按名搜)—— 需先确认 PikPak 递归搜索 API 形态。
- **E · 云端连播**(把一个文件夹当播放列表顺序播)—— 需改 IINA 播放列表接入,中上工作量。
- **F · 连接诊断面板** —— PikPak/蜜柑契约变更时给可读提示(偏防御)。

---

## 7. 文件索引(常改的地方)

| 关注点 | 文件 |
| --- | --- |
| PikPak drive API(list/play/offline/move/tasks/缓存) | `PikPak/PikPakDrive.swift` |
| PikPak 认证(登录/刷新合并/captcha) | `PikPak/PikPakAuth.swift`、`PikPakCaptchaRecapturer.swift` |
| PikPak 常量/盐/端点 | `PikPak/PikPakConfig.swift` |
| 网盘浏览器(缓存/筛选/键控/预取) | `UI/Library/PikPakBrowserView.swift` |
| 离线任务中心 | `UI/Library/PikPakTaskCenterView.swift` |
| 蜜柑(导航/抓取/缩放) | `UI/Library/MikanView.swift` |
| 媒体库窗口/缩放壳 | `UI/Library/LibraryWindowView.swift` |
| 播放桥接(mpv 远程档/进度) | `iina/IinaMagnetBridge.swift` |
| 元数据 provider 抽象 | `Metadata/MetadataProvider.swift`、`MetadataService.swift` |

测试约定:Swift Testing(`@Suite`/`@Test`/`#expect`/`#require`)。
注意 `#expect { } throws: { }` 闭包式**不编译**,用 do/catch + `Issue.record`。
PikPak 测试用 `QueueStub`/`StubPikPakClient`(按路径排队返回,支持 `delayNanos`
造并发重叠窗口;路径匹配取**最长键**优先)。

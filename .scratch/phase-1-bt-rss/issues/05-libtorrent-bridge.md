# Issue 05 · LibtorrentBridge.mm（Obj-C++ wrapper）

Status: ready-for-agent
Sprint: 1 (libtorrent 桥接)
Created: 2026-05-26
Updated: 2026-05-26
Related: [ADR-0002](../../../docs/adr/0002-libtorrent-inproc.md), PRD §IM-3
BlockedBy: 04
Blocks: 06

## 描述

写 Obj-C++ 层（`.mm`）封装 libtorrent C++ API，公开纯 Obj-C 接口（不外泄 C++ 类型）给 Swift 调用。

## 验收标准

- [ ] 目录 `iina-magnet/Sources/LibtorrentBridge/`（独立 Obj-C target）
- [ ] 公开头文件 `LibtorrentBridge.h`：
  ```objc
  @class LMSessionSettings, LMTorrentStatus, LMAlert;

  @interface LMSession : NSObject
  - (instancetype)initWithSettings:(LMSessionSettings *)settings;
  - (nullable NSString *)addMagnet:(NSString *)magnetURI savePath:(NSString *)path;
  - (nullable NSString *)addTorrentFile:(NSData *)torrentData savePath:(NSString *)path;
  - (void)pauseTorrent:(NSString *)infoHash;
  - (void)resumeTorrent:(NSString *)infoHash;
  - (void)removeTorrent:(NSString *)infoHash deleteFiles:(BOOL)deleteFiles;
  - (void)setPieceDeadline:(NSString *)infoHash piece:(int)piece deadlineMs:(int)ms;
  - (void)setSequentialDownload:(NSString *)infoHash enabled:(BOOL)enabled;
  - (nullable LMTorrentStatus *)statusOf:(NSString *)infoHash;
  - (NSArray<LMAlert *> *)pumpAlerts;
  @end
  ```
- [ ] `LMSessionSettings`：listenPort、enableDHT、enablePEX、enableLSD、enableUPnP、encryptionPolicy、uploadRateLimit、downloadRateLimit
- [ ] `LMTorrentStatus`：name、totalSize、downloadedBytes、uploadedBytes、numPeers、numSeeds、state、downloadRate、uploadRate、progress、pieces (NSData bitfield)
- [ ] `LMAlert`：type、infoHash、message、timestamp。覆盖 alerts：metadata_received、piece_finished、file_completed、torrent_finished、torrent_error、save_resume_data
- [ ] 实现 `.mm` 文件：
  - `libtorrent::session` 持有为 `std::unique_ptr`
  - `info_hash` ↔ `NSString`（hex 转换）
  - `pumpAlerts`：调 `session.pop_alerts(...)`，遍历 vector 转换为 `[LMAlert]`
- [ ] 单元测试（Swift `@Test`）：
  - 构造 session 与 settings → 不崩溃
  - addMagnet 给一个 valid magnet URI → 返回非 nil infoHash
  - addMagnet 给 invalid URI → 返回 nil
  - pumpAlerts 在空 session 上返回空数组
  - addTorrentFile 给一个本地 .torrent fixture（如 Ubuntu iso）→ 返回正确 infoHash

## 实现提示

- `.mm` 与 `.h` 严格分开：`.h` 只用 Obj-C / Foundation 类型，`.mm` 才包含 `<libtorrent/...>` headers
- 头文件 ARC 用 `__attribute__((objc_arc))` 或 target 设置 ARC on
- libtorrent alert 用 `read_handler` callback 也可，但首版用 pump 简单
- info_hash 转 hex：用 libtorrent 自带 `aux::to_hex`，或自己 `[NSData -dataUsingHexEncoding]`-反向
- 不要内置 tracker URL 列表（违 PRD US-41）

## Out of scope

- Swift TorrentManager actor（→ Issue 06）
- 流式播放算法（→ Issue 07）

## Comments

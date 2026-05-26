# ADR-0002 · libtorrent (Rasterbar) 进程内桥接

Status: Accepted
Date: 2026-05-26
Related: [ADR-0001](./0001-fork-iina-gpl3.md), [ADR-0004](./0004-swiftui-independent-windows.md)

## Context

Phase 1 的核心能力是 **"边看边播"**——torrent 文件未下完时就能用 mpv 播放。这要求 BT 引擎具备：

1. **顺序下载**（`sequential_download = true`）
2. **piece 优先级**（按 mpv 当前播放位置动态调整 piece deadline）
3. **sparse file 输出**（已下载部分落盘到正确偏移，未下载部分保留 0 字节空洞）
4. **多 torrent 并发**
5. **稳定**（用户会同时管理 5-20 个订阅任务）

并需要 BT 协议本体能力（DHT / PEX / Magnet / WebSeed / encryption），最好生态成熟。

## Decision

**用 libtorrent (Rasterbar) C++ 库**，通过 **Obj-C++ wrapper（.mm 文件）** 桥接到 Swift。libtorrent **运行在主 App 进程内**（不独立 daemon）。

数据流：

```
libtorrent::session
  ↓ sequential_download + set_piece_deadline
sparse 文件（macOS APFS 原生支持）
  ↓ file:// URL
iina PlayerCore → mpv
  ↓ open file
mpv 读到未下载偏移 → read returns 0 (EOF-like) → mpv buffer 等待
```

mpv 在 `--cache=yes --demuxer-readahead-secs=...` 模式下，对部分文件读到 EOF 会重试，配合 libtorrent piece 完成回调即可继续播放。

## Alternatives Considered

### A. libtorrent 独立 daemon + RPC

启一个 helper 进程跑 libtorrent，主 App 通过 XPC / JSON-RPC 调用。

- ✓ 崩溃隔离
- ✓ libtorrent 升级不动主 App
- ✗ Sandbox 下 XPC service 设计复杂
- ✗ piece 状态轮询走 RPC 增加延迟（边看边播每秒查询多次）
- ✗ 工程量 +2-3 周

放弃理由：本项目早期不考虑崩溃隔离，工程成本远超收益。可作为 Phase 3+ 选项。

### B. aria2 进程 + JSON-RPC

复用 aria2 二进制。

- ✓ 现成下载器，安装简单
- ✗ aria2 是"下载器"不是"流式播放器"：piece priority API 粗，常优先选最稀有 piece 拼成种，与播放需求冲突
- ✗ 顺序下载选项有，但 piece deadline 控制弱，可能导致播放头前几十秒缓冲缺失

放弃理由：技术目标错配。

### C. WebTorrent + JSCore

用 WebTorrent (Node/JS) 在 JSCore 上跑。

- ✓ JS 生态熟悉
- ✗ WebTorrent 主要走 WebRTC，**与传统 BT 协议（TCP/uTP）peer 池不互通**
- ✗ JS 性能 / 内存开销大
- ✗ 嵌入 JSCore 引擎复杂

放弃理由：协议不兼容，无法在 mikanani 等传统 BT 站工作。

### D. 自研

✗ 6+ 月起步。BT 协议、DHT、tracker 实现都是大工程。放弃。

## Consequences

### 正面

- 直接读 sparse file，零进程间通信开销
- 与 mpv 集成最直接：mpv 不需要 HTTP server / FUSE / pipe
- libtorrent 是业界标准（Transmission / qBittorrent / Deluge 都用它），社区文档丰富
- 边看边播延迟最低（piece 完成事件 → mpv buffer 就绪 在同一进程内 ns 级）

### 负面与缓解

| 负面 | 缓解 |
| --- | --- |
| libtorrent 崩溃会带崩主 App | 用 release 版 libtorrent，禁用 debug assertions；崩溃报告关键栈以判断是否需要切独立进程 |
| C++ 编译链与 Boost 依赖 | 用 libtorrent 2.x（C++17，新版去 Boost-system 依赖）；预编译为静态库 |
| App 二进制变大（+10-15 MB） | 接受。macOS App 体积不敏感 |
| libtorrent API 变化频繁 | 锁定 minor 版本；wrapper 集中变化点 |
| macOS Sandbox 与 BT 协议 inbound socket 冲突 | **不启 App Sandbox**（与 iina 同步）。会失去 Mac App Store 分发能力，但本项目本就 GitHub 发布 |

## 实施约定

- libtorrent 版本：**2.0.x**（C++17，去 Boost-system 依赖）
- 编译为 universal static library（arm64 + x86_64），用 `lib/libtorrent/build.sh` 脚本固化
- 所有 libtorrent 类型不外泄到 Swift；Wrapper 公开的接口只用：`NSString`、`NSData`、`NSURL`、整型、自定义 `LMTorrentStatus` Obj-C 类
- libtorrent alert pumping：单独 Swift `TimerActor`，50ms 轮询，转 `AsyncStream`
- piece deadline 策略：
  - 播放头 → 接下来 30 秒 piece：`deadline = 0ms, alert = yes`
  - 接下来 60 秒：`deadline = 1000ms`
  - 之外：`deadline = 10000ms`
- 资源回收：torrent 删除时清理 sparse 文件；除非用户选择"保留文件"

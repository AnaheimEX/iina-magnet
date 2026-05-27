# Issue 16 · Magnet Settings 窗口

Status: completed (merged to develop)
Sprint: 4 (UI)
Created: 2026-05-26
Updated: 2026-05-26
Related: PRD US-7xx, US-40
BlockedBy: 06

## 描述

独立 SwiftUI Settings 窗口（不嵌入 iina Settings），承载 BT / RSS / 路径 / Disclaimer 等全局配置。

## 验收标准

- [ ] 注册 `Settings { ... }` SwiftUI scene 或独立 `Window(id: "magnet.settings")`
- [ ] 主菜单 "Magnet > Settings…" + cmd+,
- [ ] Tab 布局：
  - **General**：
    - cache 路径（默认 `~/Library/Application Support/iina-magnet/cache/`）
    - 下载完成路径（必填）
    - 下载完成后自动移动 toggle
    - 磁盘空间预警阈值 GB
  - **BitTorrent**：
    - 监听端口（默认 6881，可改）
    - 启用 DHT / PEX / LSD（默认开）
    - 启用 UPnP（默认关，警告说明）
    - 加密策略（强制 / 优先 / 关闭，默认强制）
    - 上行限速（默认 0=无限）
    - 下行限速（默认 0=无限）
    - 并发 torrent 上限（默认 5）
    - 做种策略（默认 "零做种"），可改：零 / 比例 1.0 / 比例 2.0 / 永久
  - **RSS**：
    - 全局默认轮询区间（覆盖给新订阅源用，默认 30min）
    - 自动启动下载 toggle（默认开；关后命中只入"待下载队列"）
  - **About**：
    - 版本号、build commit hash
    - "查看 Disclaimer" 按钮 → 弹 Disclaimer sheet（复用 Issue 02 组件）
    - 链接：项目主页、Issues、License
- [ ] 设置变更立即生效：
  - 端口 / DHT / 加密改变 → `TorrentManager.applySettings(...)` 重启 session
  - 下载路径改变 → 不迁移老任务（提示用户）
  - 轮询区间改变 → 仅影响新源
- [ ] 持久化：`AppStorage` 或 SwiftData 单条 `AppSettings` model
- [ ] 验收测试：改端口 → 重启 BT session → BT Manager 中能看到新端口

## 实现提示

- `Settings { ... }` scene 在 macOS 上自动支持 cmd+,
- `AppStorage` 简单 key-value 用；嵌套结构（如 customHeaders）用 SwiftData
- 路径选择用 `NSOpenPanel`（folder 模式）

## Out of scope

- Phase 2 媒体库相关 settings（未来 Issue）

## Comments

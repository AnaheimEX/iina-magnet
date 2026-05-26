# Issue 14 · RSS Manager 窗口

Status: ready-for-agent
Sprint: 4 (UI)
Created: 2026-05-26
Updated: 2026-05-26
Related: [ADR-0004](../../../docs/adr/0004-swiftui-independent-windows.md), PRD US-1..16, US-45
BlockedBy: 11, 12, 13

## 描述

SwiftUI 独立窗口（id `magnet.rss-manager`），承载订阅源管理、规则编辑、Feed 预览、命中历史。

## 验收标准

- [ ] 在 `IinaMagnetApp` 注册 `Window(id: "magnet.rss-manager")`
- [ ] 主菜单 "Magnet > RSS Manager…" 触发 `openWindow(id:)`
- [ ] 布局（NavigationSplitView）：
  - **Sidebar**：订阅源列表，每条显示：图标 + displayName + 上次拉取时间 + 状态徽章（成功 ✓ / 错误 ⚠️ / 禁用 ⏸）；底部 + / – 按钮
  - **Detail**：选中 source 后显示三个 tab：
    - **Settings**：URL、display name、pollInterval（Picker 15min/30min/1h/3h/6h/12h）、cookie/header 自定义（KV 编辑器）、enabled toggle
    - **Rules**：规则列表 + + 添加规则 → 弹出规则编辑器：name、include[]、exclude[]、regex (toggle)、caseSensitive、enabled
    - **Feed 预览**：右上"立即拉取"按钮；下方表格：title、publishedAt、是否匹配（命中规则名）、enclosure 类型（magnet / torrent）
  - **Status 区**（detail 底部）：上次拉取时间、上次结果、下次预计时间
- [ ] 规则编辑器对话框：
  - include/exclude 是 chips 输入（按回车添加，点 × 删除）
  - regex 开启时显示 regex 输入框，include/exclude 灰显
  - "试匹配"按钮：用当前订阅源最近 50 条 FeedItem 跑 RuleEngine，下方显示命中条数 + 前 5 条
- [ ] 命中历史 view（来自 sidebar 顶部"全部命中"）：跨所有 source 的最近 200 条 Match，按时间倒序
- [ ] CRUD：增/删 source + rule 不刷新整个 view（用 SwiftData `@Query` 自动响应）
- [ ] 错误展示：source 拉取失败时 sidebar 徽章变红，detail 顶部 banner 显示错误
- [ ] 多语言：所有 UI 字符串走 String Catalog
- [ ] 验收测试（手工）：
  - 添加一个 nyaa.si magnet RSS（公开源，可用 https://nyaa.si/?page=rss）→ 拉取成功
  - 添加规则 `include=["1080p"]` `exclude=["RAW"]` → 试匹配显示命中数
  - 启用 → 等下次轮询 → 命中条目出现在 BT Manager 任务列表

## 实现提示

- `@Query` 拿 `[SubscriptionSource]`，`@Bindable` 双向绑定
- KV header 编辑器：可用 `Table` + add/remove row
- chips 输入：自写小组件（`FlowLayout` + 圆角 Capsule）
- 试匹配按钮调 `RssRuleEngine.evaluate` 直接同步执行（数据小）

## Out of scope

- BT Manager（→ Issue 15）
- Settings（→ Issue 16）

## Comments

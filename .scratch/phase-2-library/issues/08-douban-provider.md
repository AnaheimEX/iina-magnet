# Issue 08 · DoubanProvider（爬虫，默认关闭）

Status: ready-for-agent
Sprint: 2 (Metadata)
Created: 2026-05-29
Updated: 2026-05-29
Related: [ADR-0005](../../../docs/adr/0005-multi-source-metadata.md), PRD §IM-11
BlockedBy: 05
Blocks: 11

## 描述

实现豆瓣源——中文片名 / 中文剧情 / 中文演员名首选。豆瓣**无官方 API**，走 web 爬虫，反爬严重。**默认关闭**，用户在 Settings 主动启用。失败静默 fallback，不阻塞其它源。爬虫规则隔离到独立文件，便于热替换。

## 验收标准

- [ ] `iina-magnet/Sources/IinaMagnet/Metadata/Providers/Douban/DoubanProvider.swift`
- [ ] `iina-magnet/Sources/IinaMagnet/Metadata/Providers/Douban/DoubanScraper.swift`：搜索页 + 条目页 HTML 解析规则集中此处
- [ ] `search`：豆瓣搜索 → top-3（标题 + 年份 + 海报）；`details`：条目页 → titleZh、overview-zh、cast(中文名)、doubanRating、posterURL、releaseYear
- [ ] 默认 `enabled=false`；仅当 AppSettings 开启时进 Registry
- [ ] 反爬礼貌：随机 UA、请求间隔、失败退避；命中反爬（403/验证页）→ 抛 `DoubanBlockedError`，编排层静默跳过
- [ ] fixture 单测 `Tests/fixtures/metadata/douban/`（保存的搜索页 + 条目页 HTML，去敏感）：
  - 解析搜索结果列表
  - 解析条目页中文字段 + 评分
  - 反爬页 HTML → 抛 DoubanBlockedError

## 实现提示

- 解析用 `Foundation` 的正则 / 简单 HTML 切片或轻量解析；不引重型 HTML 库（项目原则少依赖）
- 所有选择器 / 正则集中 `DoubanScraper`，注释标 "反爬变更时改这里"
- 不内置任何登录态；只匿名抓公开页

## Out of scope

- 合并 / 编排（→ 10/11）

## Comments

# Issue 12 · RssService Fetcher + Parser

Status: ready-for-agent
Sprint: 3 (RSS)
Created: 2026-05-26
Updated: 2026-05-26
Related: PRD US-1xx, US-2xx
BlockedBy: 10
Blocks: 13, 14

## 描述

`Fetcher`：用 cookie/header 拉取 RSS URL，返回 raw data 与状态。
`Parser`：解析 RSS 2.0 / Atom，输出 `[ParsedFeedItem]`。
两者都是 thin layer，可独立测试。

## 验收标准

- [ ] `Fetcher`：
  ```swift
  struct FetchResult: Sendable {
      let data: Data
      let etag: String?
      let lastModified: String?
      let httpStatus: Int
  }

  protocol Fetcher: Sendable {
      func fetch(url: URL, cookies: String?, headers: [String: String]) async throws -> FetchResult
  }

  struct URLSessionFetcher: Fetcher { ... }
  ```
  - 实现：URLSession `data(for: URLRequest)`
  - cookies 直接放 `Cookie` header
  - 自定义 headers 覆盖 default
  - User-Agent 设为 `iina-magnet/<version> (+https://github.com/<repo>)`
  - timeout 30s
- [ ] `Parser`：
  ```swift
  struct ParsedFeedItem: Sendable, Equatable {
      let guid: String
      let title: String
      let enclosureURL: URL
      let publishedAt: Date?
      let rawDescription: String?
  }

  enum FeedFormat { case rss2, atom }

  struct FeedParser {
      static func parse(_ data: Data) throws -> (format: FeedFormat, items: [ParsedFeedItem])
  }
  ```
  - 用 `XMLParser`（Foundation）或纯 Swift XML 库
  - RSS 2.0：`<item>` 下 `<title>`, `<enclosure url=...>`, `<guid>`, `<pubDate>`
  - Atom：`<entry>` 下 `<title>`, `<link rel="enclosure" href=...>`, `<id>`, `<published>`
  - guid 缺失时 fallback 到 enclosure URL 的 hash
  - magnet link 在 `<enclosure>` 中（非标准但 mikanani 等用）也支持
- [ ] 集成测试：
  - `tests/fixtures/rss/mikanani-sample.xml`（脱敏样本）→ 解析 ≥ 1 条 item
  - `tests/fixtures/rss/nyaa-sample.xml` → 同上
  - `tests/fixtures/rss/atom-sample.xml` → 同上
  - 损坏 XML → throws，error 信息可读
  - 空 channel → 返回 `(rss2, [])`
- [ ] Fetcher 集成测试用本地 HTTP server fixture（启在测试 setUp）
- [ ] 不允许测试中真实访问 mikanani / nyaa（fixture 化）

## 实现提示

- RSS 与 Atom 区分用根元素 tag（`<rss>` vs `<feed>`）
- 日期格式：RFC 822 (RSS) / ISO 8601 (Atom)，用 `Date.ISO8601FormatStyle` 与 `DateFormatter` 两套
- magnet link 在 enclosure：检查 `url` 属性是否 `magnet:` 开头

## Out of scope

- Scheduler（→ Issue 13）
- Rule 引擎（→ Issue 11，已做）

## Comments

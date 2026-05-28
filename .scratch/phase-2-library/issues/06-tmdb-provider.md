# Issue 06 · TMDBProvider

Status: ready-for-agent
Sprint: 2 (Metadata)
Created: 2026-05-29
Updated: 2026-05-29
Related: [ADR-0005](../../../docs/adr/0005-multi-source-metadata.md)
BlockedBy: 05
Blocks: 11

## 描述

实现 `MetadataProvider` 的 TMDB 源——主源，覆盖电影 / 美/英/韩/港剧。支持 movie 与 tv 两类查询，多 locale（zh-CN 取中文、en-US 取英文 backdrop）。fixture 单测，不联网。

## 验收标准

- [ ] `iina-magnet/Sources/IinaMagnet/Metadata/Providers/TMDBProvider.swift`
- [ ] `search`：调 `/search/multi` 或按 kindHint 分流 `/search/movie`、`/search/tv`；返回 top-3 `MetadataCandidate`
- [ ] `details`：movie 走 `/movie/{id}`，tv 走 `/tv/{id}` + `append_to_response=credits` + seasons/episodes；填 `MetadataDetails`（titleZh/En, overview-zh, poster 最大尺寸, backdrop en-US, releaseYear, cast 含 zh-CN, crew, seasons[], episodes[], genres, tmdbRating）
- [ ] API key 从 AppSettings 注入；缺 key 时该 provider 不应被 Registry 装载（在 Issue 05 处理；本 issue 假设有 key）
- [ ] 复用 Phase 1 `URLSessionFetcher` 风格的网络层；遵守 Issue 05 RateLimiter
- [ ] fixture 单测 `Tests/fixtures/metadata/tmdb/`（真实响应 JSON，去 key）：
  - movie search + details 映射正确
  - tv search + details + seasons/episodes 映射正确
  - 中文 locale 字段映射
  - 网络错误 / 404 抛预期错误（由编排层隔离）

## 实现提示

- 海报 URL 拼 `https://image.tmdb.org/t/p/original` + path
- backdrop 用 en-US 避免内嵌中文字幕（ADR-0005）
- cast 取前 ~15 个；crew 取 director/创作者

## Out of scope

- 合并 / 编排 / 相似度（→ 10/11/09）

## Comments

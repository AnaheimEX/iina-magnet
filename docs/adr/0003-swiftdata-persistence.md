# ADR-0003 · SwiftData 作为主持久化方案

Status: Accepted
Date: 2026-05-26
Related: [ADR-0001](./0001-fork-iina-gpl3.md)

## Context

需要在本地持久化：

- 订阅源、规则、Feed 去重表（Phase 1）
- TorrentTask 状态（Phase 1）
- Title / Season / Episode / VersionFile / Tag / WatchProgress（Phase 2）
- Disclaimer 同意记录

预期规模：数万条 Episode + 几千条 VersionFile + 千条 Feed 记录。

查询需求：

- 按 Title / 标签 / 类型筛选
- 按观看进度排序
- 按更新时间排序
- 跨表 join（找未看的某标签下作品）

最低系统 macOS 14（[已决策](../../DEVELOPMENT_PLAN.md) §2.3），可以使用 SwiftData。

## Decision

**用 SwiftData 作为唯一持久化层**。Schema 见 [ARCHITECTURE.md §2.4](../../ARCHITECTURE.md#24-persistence-layer)。

数据库文件：`~/Library/Application Support/iina-magnet/Library.sqlite`（SwiftData 底层是 SQLite）

## Alternatives Considered

### A. Core Data

- ✓ 老牌成熟、文档全
- ✓ 与 Obj-C 互操作好（不过本项目新模块全 Swift）
- ✗ NSManagedObject / NSPredicate 时代代码风格与 SwiftUI/Observation 不匹配
- ✗ Apple 未来重点在 SwiftData

放弃理由：本项目从 0 开始，没有迁移负担，直接上现代方案。

### B. GRDB (SQLite)

- ✓ 性能强、SQL 可控、迁移清晰
- ✓ 大数据集（10w+ 条）表现稳定
- ✗ 需手写 SQL；模型层代码比 SwiftData 多 3-5 倍
- ✗ 与 SwiftUI 集成需自己写 publishers / observation

放弃理由：本项目数据量在 SwiftData 舒适区，GRDB 优势用不到。**保留为 Phase 2 性能不达预期时的 fallback 方案**。

### C. Realm

- ✗ 商业公司维护（被 MongoDB 收购）
- ✗ 二进制依赖
- ✗ 与 Apple 原生生态偏离

放弃。

### D. 文件 + JSON / Plist

- ✓ 简单
- ✗ 查询都要全表扫；几万条数据下不可用

放弃。

## Consequences

### 正面

- 代码量最小，开发速度最快
- 与 SwiftUI 5 / Observation `@Query` / `@Model` 一体化
- 自动迁移（轻量场景）
- 无第三方依赖

### 负面与缓解

| 负面 | 缓解 |
| --- | --- |
| SwiftData 在 macOS 14 早期版本有 bug（多上下文、迁移） | 锁 macOS 14.4+ 测试；准备 Migration plan；Phase 2 早期做大数据集压测 |
| 复杂查询（多表 join、复杂 Predicate）写法受限 | 复杂场景手写 FetchDescriptor + 自定义 Predicate；个别极端情况下 fallback 到直接 SQL |
| 跨数据库版本迁移坑（已知 Apple bug） | 写迁移测试；每个 schema 变更出对应 `SchemaMigrationPlan` 文件 |
| 与 SwiftData CloudKit Adapter 后续要不要走还没定 | 现阶段不做同步（[DEVELOPMENT_PLAN.md](../../DEVELOPMENT_PLAN.md) §3）。如启用，再写新 ADR |

## 实施约定

- Schema 改动必须**新增 `SchemaMigrationPlan` 条目**，不允许直接改老 `@Model`
- 所有 `@Model` 类放在 `iina-magnet/Persistence/Models/`，一个文件一个类
- 所有 `ModelContainer` 创建走 `PersistenceController.shared`（单例）
- 重读/重写大量数据用 `ModelContext` 显式 batch + `try context.save()`，不在主线程
- 性能基准（Phase 2 必跑）：
  - 1w 条 Episode 全表 query：< 100ms
  - 1k 条 VersionFile insert：< 500ms
  - 启动加载主界面所需数据：< 200ms

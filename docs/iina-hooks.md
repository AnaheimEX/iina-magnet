# iina Upstream Hooks Registry

> 本项目对 iina upstream 原代码的**所有改动**都登记在这里。每次 `git merge upstream/develop` 后必须人工核对每一条仍在生效。
>
> 决策依据：[ADR-0001](./adr/0001-fork-iina-gpl3.md) — Fork iina + 直接增强。
>
> 工作流见：[sync-workflow.md](./sync-workflow.md)。

---

## 注册规则

- 每个 hook 都在源码处加注释 `// MARK: iina-magnet hook`（Obj-C 用 `// MARK: iina-magnet hook`，C++ 用 `// iina-magnet hook`）
- 一个文件可有多个 hook，每处独立注释
- 新增 hook 必须同时更新本表，与代码 PR 一起合入
- 删除 hook 同上

## 当前注册表

| # | 文件 | 行数（最近一次 sync 时） | hook 用途 | 由哪个 Issue 引入 | 状态 |
| --- | --- | --- | --- | --- | --- |
| H-001 | `Configs/Deployment.xcconfig` | 12-13 | macOS 部署目标从 11/12 升到 14（SwiftData 要求） | Issue 01 (Phase 0) | active |
| H-002 | `other/download_libs.sh` | 3-4 | `PROJECT_NAME` 由 env 覆盖（fork repo 目录名 `iina-magnet` ≠ 上游硬编码的 `iina`） | Issue 01 (Phase 0) | active |
| H-003 | `.github/workflows/ci.yml` | 24-25 | `Install dependencies` step 加 `PROJECT_NAME: iina-magnet` env | Issue 01 (Phase 0) | active |

### 即将引入（按 Issue 计划）

| 文件 | hook 用途 | 引入 Issue |
| --- | --- | --- |
| `iina/AppDelegate.swift` | 在 `applicationDidFinishLaunching` 调 `IinaMagnetBootstrap.start()`；在 `applicationWillTerminate` 调 `.shutdown()` | Issue 03 |
| iina 主菜单（XIB 或代码） | 增加 "Magnet" 顶层菜单 | Issue 03 |
| `iina.xcodeproj/project.pbxproj` | 链入 `iina-magnet/` Swift package 到 iina 主 target | Issue 03 |
| `iina/PlayerCore.swift` | 增加 `magnetStreamCoordinator` 属性 + 在 time-pos / seek 通知该 coordinator | Issue 08 |

---

## Sync 回归清单（merge upstream 后必跑）

每次 sync 之后人工核对：

- [ ] **H-001**：`Configs/Deployment.xcconfig` 中 `MACOSX_DEPLOYMENT_TARGET = 14`（含 arm64 override）
- [ ] **H-002**：`other/download_libs.sh` 第 3-4 行仍是 `PROJECT_NAME="${PROJECT_NAME:-iina}"`（env-overridable，不是硬编码 `'iina'`）
- [ ] **H-003**：`.github/workflows/ci.yml` `Install dependencies` step 仍包含 `PROJECT_NAME: iina-magnet` env
- [ ] (后续 hook 引入后扩展此清单)

如有 hook 在 upstream 被 "无意覆盖"（如 upstream 改了 AppDelegate 把我们的 hook line 移走），在 sync 分支立即补回，commit message 用 `fix(iina-sync): restore hook H-NNN after upstream refactor`。

---

## hook 设计原则

1. **最小侵入**：每个 hook ≤ 3 行代码，且只在 lifecycle / event 点
2. **不改语义**：hook 只追加副作用，不修改 upstream 行为
3. **可摘除**：所有 hook 删除后 iina 应仍能正常工作（仅没有 magnet 功能）
4. **明示标记**：必须有 `// MARK: iina-magnet hook` 注释
5. **集中持有引用**：iina 原 class 持有 IinaMagnet 类型时用 protocol + weak（避免循环依赖编译期暴露）

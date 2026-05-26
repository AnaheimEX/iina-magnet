# Issue 01 · Fork iina 与工程基线

Status: ready-for-agent
Sprint: 0 (Foundation)
Created: 2026-05-26
Updated: 2026-05-26
Related: [ADR-0001](../../../docs/adr/0001-fork-iina-gpl3.md), [ADR-0003](../../../docs/adr/0003-swiftdata-persistence.md)
Blocks: 02, 03, 04, 10, 19

## 描述

建立 iina-magnet 工程基线：fork iina、升级 deployment target、新增独立 Swift package target、CI、SwiftData 容器。

之后所有 issue 在这个基线上展开。

## 验收标准

- [ ] 在 GitHub 上 fork `iina/iina` 到 `iina-magnet`（用户操作；本 issue 仅准备工作流）
- [ ] 本地 clone 到 `/Users/anaheim/Downloads/vibe coding/Claude Project/iina-magnet/iina-source/`
- [ ] `git remote -v` 含 `origin` (iina-magnet fork) 与 `upstream` (iina/iina)
- [ ] Xcode 项目 deployment target 改为 macOS 14.0
- [ ] 项目根增加 `iina-magnet/` 顶层 Swift package（独立 target `IinaMagnet`），含：
  - `Sources/IinaMagnet/Bootstrap.swift` —— 一个空的 `IinaMagnetBootstrap.start()` / `.shutdown()`
  - `Sources/IinaMagnet/Persistence/PersistenceController.swift` —— SwiftData `ModelContainer` 单例骨架，schema 空
  - `Tests/IinaMagnetTests/SmokeTest.swift` —— 一条断言 1+1=2 的烟测，保证 swift test 链路通
- [ ] iina 主 target 在 build settings 链入 `IinaMagnet` package
- [ ] CI 配置文件提交：
  - `.github/workflows/build-and-test.yml`：PR 触发 `xcodebuild test` + `swift test`
  - main 触发 release build artifact 上传
- [ ] `docs/sync-workflow.md` 写好（步骤、回归清单、merge commit message 模板）
- [ ] cmd+R 跑起后主播放窗口与原 iina 一致，标题栏不变（**不允许此 issue 改动用户可见 UI**）
- [ ] `git merge upstream/develop` 至少演练一次（dry-run，无实际改动），记入 sync-workflow.md

## 实现提示

- iina 的 `Info.plist` deployment target 在 Xcode project file 中（`MACOSX_DEPLOYMENT_TARGET`）。同时改 `Podfile`（如有）与 `swift-tools-version`。
- `IinaMagnet` 用 Swift Package（不用 Xcode target），便于独立 test。主 target 通过 "Add Package Dependency · Add Local…" 引用。
- `PersistenceController` 路径：`~/Library/Application Support/iina-magnet/Library.sqlite`。`FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)`。
- 不要在本 issue 引入 libtorrent / Anitomy / 其他第三方。

## Out of scope

- libtorrent 编译（→ Issue 04）
- Disclaimer 弹窗（→ Issue 02）
- 主菜单 hook（→ Issue 03）

## Comments

（实施期间记录决策/疑问/障碍）

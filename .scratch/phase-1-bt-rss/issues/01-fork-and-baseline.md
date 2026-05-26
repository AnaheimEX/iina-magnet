# Issue 01 · Fork iina 与工程基线

Status: in-progress (PR #1 open on AnaheimEX/iina-magnet)
Sprint: 0 (Foundation)
Created: 2026-05-26
Updated: 2026-05-26
Related: [ADR-0001](../../../docs/adr/0001-fork-iina-gpl3.md), [ADR-0003](../../../docs/adr/0003-swiftdata-persistence.md)
Blocks: 02, 03, 04, 10, 19

## 描述

建立 iina-magnet 工程基线：fork iina、升级 deployment target、新增独立 Swift package target、CI、SwiftData 容器。

之后所有 issue 在这个基线上展开。

## 验收标准

- [x] 在 GitHub 上 fork `iina/iina` 到 `AnaheimEX/iina-magnet`（2026-05-26 完成，`--default-branch-only`）
- [x] 本地 clone 到 `iina-source/`
- [x] `git remote -v` 含 `origin` (AnaheimEX/iina-magnet) 与 `upstream` (iina/iina)
- [x] Xcode 项目 deployment target 改为 macOS 14.0（`Configs/Deployment.xcconfig`，含 arm64 override）
- [x] 项目根增加 `iina-magnet/` 顶层 Swift package（独立 target `IinaMagnet`），含：
  - `Sources/IinaMagnet/Bootstrap.swift` —— `IinaMagnetBootstrap.start/.shutdown` idempotent stub
  - `Sources/IinaMagnet/Persistence/PersistenceController.swift` —— SwiftData `ModelContainer` 骨架（empty schema）
  - `Tests/IinaMagnetTests/SmokeTest.swift` —— swift-testing 2 用例
- [ ] **DEFERRED to Issue 03**：iina 主 target 在 build settings 链入 `IinaMagnet` package。理由：Phase 0 暂无对 IinaMagnet 的实际调用，先链入只会增加 pbxproj 改动面，与 upstream merge 冲突。Issue 03 一次性完成 "链入 + AppDelegate hook + 主菜单 Magnet"。
- [x] CI 配置文件提交：
  - `.github/workflows/iina-magnet-package.yml`：PR/push 触发 `swift build` + `swift test`（秒级反馈）
  - **没有改动** 现有 `ci.yml`（保留 iina-flagship 的 full build 不变）
- [x] `docs/sync-workflow.md` 已存在（首版规划写）
- [x] `docs/iina-hooks.md` 创建并登记 H-001（Deployment.xcconfig 改动）
- [ ] **DEFERRED 验收**：cmd+R 主播放窗口验证。需要 `./other/download_libs.sh` 拉取 iina deps（~200MB+）；建议在用户开发机首次构建时验证，或通过 CI 上 `ci.yml` 的完整 build 来证明
- [ ] **DEFERRED**：`git merge upstream/develop` 实际演练。当前 fork 刚拉，与 upstream 同步；演练在第一次 sync 周期（建议 1 周后）补做并记入 `sync-workflow.md` retro 部分

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

### 2026-05-26 · Claude Sonnet 4.6 实施会话

**完成**：
- Fork：[AnaheimEX/iina-magnet](https://github.com/AnaheimEX/iina-magnet)
- 本地 clone：`iina-source/`（develop @ 655ce446 + tags v1.4.2/v1.4.3）
- 工程基线 PR：[#1 Phase 0: bump deployment target to macOS 14 + add IinaMagnet package](https://github.com/AnaheimEX/iina-magnet/pull/1)（commit bfbc3ddf）
- 本地 `swift build` + `swift test` 通过（Swift 6.3.2 / SDK 26.5 / arm64-apple-macos14.0；2 个 swift-testing 用例 0.006s）
- Planning 仓库新增 `docs/iina-hooks.md`（H-001 登记 Deployment.xcconfig 改动）

**决策记录**：

1. **链入 IinaMagnet 到 iina 主 target 推迟到 Issue 03**。理由：Phase 0 baseline 还没有任何代码调用 IinaMagnet；现在改 pbxproj 是空操作但会增加 upstream merge 冲突面。Issue 03 一次性做 "AppDelegate hook + 主菜单 Magnet + pbxproj 链入"，pbxproj 改一次性最小化。

2. **CI 分两份 workflow**。`iina-magnet-package.yml` 只跑 SPM build+test（秒级，无 deps），新增；`ci.yml` (full iina build) 保持上游原样。push 到 `develop` / `feature/**` / `sync/**` 都触发 SPM workflow。

3. **fork 时用 `--default-branch-only`**。iina 有 ~50 个 stale 分支与 ~200 tag，default-branch-only 把 fork 缩到 ~240MB。后续 sync 时按需 `git fetch upstream <branch>`。

4. **不改 DEVELOPMENT_TEAM / Bundle Identifier**。Phase 0 保持上游设置，本地开发者签名失败时自行改为个人 team；CI 用 ad-hoc 签名（`CODE_SIGN_IDENTITY = -`）正常构建。Bundle ID rename 在临近 release 前单独 issue 处理。

**已知阻塞**：

- GitHub 在 fresh fork 默认**禁用 Actions 运行**。需要用户访问 https://github.com/AnaheimEX/iina-magnet/actions 手动点 "I understand my workflows, go ahead and enable them"。完成后 PR #1 的 CI 会自动跑起来。

**下一步**：

- 用户启用 Actions → PR #1 CI 验证 → 合入 develop
- 启动 Issue 02（Disclaimer 流程）+ Issue 03（AppDelegate hook + 菜单 + pbxproj 链入）

# Upstream Sync Workflow

> 把 `iina/iina` 的最新代码合到 `iina-magnet` fork 的标准流程。每 1-2 周执行一次，或 upstream 出关键 bug fix 时执行。
>
> 决策：[ADR-0001](./adr/0001-fork-iina-gpl3.md) — Long-running fork + 定期 merge。

---

## 0. 前置

- 主分支 `main` 始终保持可发布状态
- 新功能在 `feature/<slug>` 分支开发，合入 `main` 走 PR
- 本流程仅描述 main ← upstream 的同步

## 1. 准备

```bash
# 一次性：添加 upstream remote
git remote add upstream https://github.com/iina/iina.git
git remote -v   # 应看到 origin (iina-magnet) + upstream (iina/iina)

# 每次：抓最新
git fetch upstream
git checkout main
git pull origin main
```

## 2. 创建 sync 分支

```bash
SYNC_DATE=$(date +%Y%m%d)
git checkout -b sync/upstream-$SYNC_DATE
```

## 3. Merge

```bash
git merge upstream/develop
```

冲突处理优先级：

| 冲突文件类型 | 处理 |
| --- | --- |
| `iina-magnet/` 顶层（新增代码） | 不应该冲突；冲突说明 upstream 误碰了我们目录，需要审视 |
| `iina/` 内部 + 含 `// MARK: iina-magnet hook` 注释 | 仔细人工合并；保留 hook 注释 |
| `iina/` 内部 + 无 hook 注释 | 优先取 upstream 版本 |
| `Xcode project file (pbxproj)` | 注意保留 IinaMagnet target 与 LibtorrentBridge target 引用 |
| `Podfile` / `Package.swift` | 同上 |

## 4. 回归清单（按 `docs/iina-hooks.md` 列表）

每次 merge 后必须人工核对：

- [ ] `iina/AppDelegate.swift` 的 `IinaMagnetBootstrap.start/.shutdown` 调用仍在
- [ ] 主菜单 "Magnet" 菜单项仍在
- [ ] `PlayerCore` 的 `magnetStreamCoordinator` property 仍在
- [ ] iina-magnet package 引用仍在 build settings
- [ ] LibtorrentBridge target 仍在
- [ ] 编译通过：`xcodebuild -scheme iina-magnet -configuration Debug`
- [ ] 单测通过：`swift test`
- [ ] 集成测试通过：`xcodebuild test -scheme iina-magnet-integration`

如有失败，**在 sync 分支修复**，不要直接 push main。

## 5. 验证

启动 app，至少手工跑一遍 smoke test：

- [ ] 主播放窗口正常打开
- [ ] 用 cmd+O 打开本地视频能播放
- [ ] Magnet > RSS Manager / BT Manager 能打开
- [ ] BT Manager 中添加一个测试 magnet（用 ubuntu iso 之类公开种子）能下载

## 6. 提交与合并

```bash
git push origin sync/upstream-$SYNC_DATE
gh pr create --title "Merge upstream iina@<short-sha>" \
             --body "Sync with upstream as of $(date +%Y-%m-%d). Hooks verified."
```

PR 评审重点：

- 是否有意外的 iina 原文件改动
- hook 是否完整保留
- CI 是否绿

合并到 main 用 **merge commit**，不要 squash（保留 upstream 历史可追溯）。

## 7. Tag（可选）

如果 upstream 有 tag release，sync 后给本 fork 也打 tag：

```bash
git tag -a "iina-upstream-1.4.0" -m "Synced with iina v1.4.0"
git push origin iina-upstream-1.4.0
```

## 故障恢复

### Merge 出大量冲突无法继续

```bash
git merge --abort
# 评估：是 upstream 大改动还是我们 hook 太多？
# 若 upstream 大改：开 ADR 讨论是否调整 hook 策略
# 若我们 hook 太多：考虑抽取到 protocol 注入，减小冲突面
```

### Merge 完成后 CI 红

```bash
# 在 sync 分支直接修
# 修复 commit message 用：fix(iina-sync): <what broke>
git commit -m "fix(iina-sync): adapt PlayerCore hook after upstream refactor"
```

### upstream 引入 breaking change（如 mpv 版本升级）

- 评估对 iina-magnet 功能的影响
- 写一个 ADR 记录决策（是否跟随 / 推迟 / 派生子分支）
- 若决定推迟：sync 分支不 merge，停留在 upstream 旧 commit

## 节奏

- 每周一固定 sync（建议）
- upstream 有 critical fix 时立即 sync
- 长假前不 sync（避免假期出问题）

## Commit message 规范

- merge commit：`Merge upstream iina@<sha>`（git 默认生成的可保留）
- 适配 commit：`fix(iina-sync): ...` 或 `chore(iina-sync): ...`
- 不允许 squash 掉 upstream 合并历史

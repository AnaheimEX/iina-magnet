# 跟进上游 IINA 升级（Upstream Sync）

本项目是 [iina/iina](https://github.com/iina/iina) 的私有 fork（`AnaheimEX/iina-magnet`），
在其上叠加了媒体库 + PikPak + 蜜柑计划 + bundled Anime4K 等功能。本文是把上游
新版本合并进来、同时**完整保留本项目所有自定义功能和托管插件安全不变量**的标准流程。

> 当前上游最新稳定版：**v1.4.3**（用 `git ls-remote --tags upstream` 查最新）。

---

## 1. 设计原则：为什么冲突面很小

大部分产品代码仍在独立的 Swift Package 目录 [`iina-magnet/`](../iina-magnet)
（整个 `IinaMagnet` 库 + 测试 + bridge targets）。Anime4K 也把 JavaScript、shader、
package/catalog/trust-history 和验证工具隔离在 fork-owned 目录。上游 IINA 通常不会修改这些目录，
所以直接文本冲突很少。

真正需要人工保护的是少数 IINA host lifecycle、JavaScript API 和 Xcode build phase
触点。它们不一定都有统一的 `// MARK`；合并时必须按下面的完整清单和不变量复核，
不能只搜索旧的 bootstrap hook。

---

## 2. Fork 改动清单（Manifest）

> 权威做法：fetch 上游后用
> `git diff <base>...HEAD --stat`（`base` = `git merge-base HEAD upstream/master`）
> 看实际差异。下表是人工维护的快速参照。

### A. 纯新增文件（fork 独有，**不会冲突**，合并时全部保留）
| 路径 | 作用 |
| --- | --- |
| `iina-magnet/` | 全部自定义功能所在的 SPM 包（库 + 测试 + bridge） |
| `iina-magnet/Sources/IinaMagnet/Anime4K/` | managed package policy、catalog/full-tree verifier、atomic transaction、local-path resolver |
| `iina-magnet/Tests/IinaMagnetTests/BundledPlugin*Tests.swift`、`PluginLocalPathResolverTests.swift` | managed install/upgrade/recovery/resolver 回归锁 |
| `iina/IinaMagnetBridge.swift` | iina 侧实现 `IinaBridge`（播放/进度/网络选项） |
| `iina/BundledPluginManager.swift` | app 侧 Anime4K trusted prepare、冲突 fail-off 与迁移提示 adapter |
| `deps/plugins-src/anime4k/` | fork-owned Anime4K runtime/UI/shader/license/test 源；`trusted-catalogs/<version>.catalog.json` 是不可覆盖的版本化完整树信任历史 |
| `deps/plugins/anime4k.iinaplgz`、`deps/plugins/anime4k.catalog.json`、`deps/plugins/anime4k.trusted-catalogs.json` | deterministic managed archive、当前 catalog 与签名 app 内聚合 trust-history |
| `scripts/build-anime4k-plugin.py` | package/catalog/trust-history reproducible builder 与 `--check` gate |
| `scripts/anime4k_libmpv_probe_validator.py`、`scripts/run-anime4k-libmpv-probe.sh` | bundled libmpv `glsl-shaders` contract probe/validator |
| `Configs/Anime4KPluginInputs.xcfilelist`、`Configs/Anime4KPluginOutputs.xcfilelist` | Xcode Copy Default Plugins 的精确输入/输出 |
| `tests/test_anime4k_*.py`、`tests/test_javascript_polyfill_timer_lifecycle.py`、`tests/fixtures/anime4k-libmpv-probe.iinaplugin-dev/` | package、host integration、libmpv probe fixtures/tests |
| `lib/anitomy/` | Anitomy C++ bridge 的 vendored 源（文件名解析） |
| `other/iina-magnet-link.rb` | fork 辅助脚本 |
| `.github/workflows/iina-magnet-package.yml` | 包的 CI |
| `README.iina-magnet.md`、`docs/`（本文件等） | fork 文档 |

### B. 修改了上游文件（**冲突点**，合并时需保留 hook、合上上游新代码）
| 路径 | 改了什么 | 解决冲突要点 |
| --- | --- | --- |
| `iina.xcodeproj/project.pbxproj` | 引用本地包/bridge/manager，并改造 Copy Default Plugins phase | **最易冲突**。重挂 package/source 后还必须恢复 Anime4K input/output file lists 与 verified copy script（见 §5） |
| `iina/AppDelegate.swift` | 启动 prepare/提示、IinaMagnet bootstrap/shutdown、legacy default-plugin skip | 保证 `BundledPluginManager.prepare()` 早于 lazy plugin inventory/player instance；app ready 后才 `presentPendingResolution()`；保留 managed archive skip |
| `iina/JavascriptAPIFile.swift` | 增加受限 `iina.file.resolveLocal` | 只能解析单个 `@data`/`@tmp` 文件；不得扩大为任意路径权限 |
| `iina/JavascriptPlugin.swift` | global instance reload/remove 前同步 unload | 保留 `prepareForUnload()` 先于 instance 释放/重建的顺序 |
| `iina/JavascriptPluginInstance.swift` | idempotent synchronous `iinaPluginWillUnload` host hook | hook 执行时 mpv/API 仍须可用；之后再取消 timer/API cleanup |
| `iina/JavascriptPolyfill.swift` | pending/active timer registry 与取消竞态修复 | `clear*`/unload 必须同时取消尚未 materialize 的 timer；one-shot 完成后移出 registry |
| `iina/PlayerCore.swift` | player plugin clear/reload 前同步 unload | 每个 instance 只 prepare 一次；先 cleanup owned shader，再从 map/array 删除 |
| `iina/InitialWindowController.swift` | 启动页「媒体库」按钮（`setUpMediaLibraryButton`） | 同上 |
| `other/download_libs.sh` | 顶部 `PROJECT_NAME` 默认值 hook（让 fork 目录名也能跑） | 保留该 hook，其余采上游（上游常改 dylib 版本） |
| `Configs/Deployment.xcconfig` | 部署目标 macOS 14（SwiftData/库需要） | 若上游提高了部署目标取较高者；否则保留 14 |
| `.gitignore` | 追加忽略项 | 取并集 |
| `.github/workflows/ci.yml` | 视情况微调 | 取并集 |

### C. Anime4K 合并不变量（冲突解决后逐项复核）

1. `BundledPluginManager.prepare()` 必须在首次访问 `JavascriptPlugin.plugins` 或创建
   player plugin instance **之前**运行；未验证、损坏或多 owner 状态必须 fail off。
2. `presentPendingResolution()` 只能在 app ready 后非阻塞展示；取消、无 window、迁移失败
   都保持 fork/community 两个 renderer disabled，不能静默选择 owner。
3. legacy default-plugin installer 必须跳过 manager 接管的
   `anime4k.iinaplgz`，避免绕过 trusted catalog set 和 transaction。
4. `iina.file.resolveLocal` 在 standardized root 下只接受 flat `@data`/`@tmp` 单文件名，
   拒绝 nested、traversal、absolute 与 lexical-root escape；这里不宣称额外的文件系统级
   symlink hardening。
5. global/player reload、disable、remove、shutdown 继续采用 synchronous unload ordering；
   `iinaPluginWillUnload` 先移除 Anime4K-owned shaders，随后才销毁 API/timer/context。
6. `JavascriptPolyfill` 保留 pending + active timer 双状态取消模型，避免 unload 与
   main-queue timer materialization 的竞态复活。
7. Xcode **Copy Default Plugins** phase 必须先运行
   `scripts/build-anime4k-plugin.py --check`，再复制 archive + current catalog + trust-history，并用 `cmp`
   验证 built resources；input/output `.xcfilelist` 不能丢。
8. archive、current catalog 与聚合 trust-history 必须 deterministic/current；每次版本升级
   必须新增对应 `trusted-catalogs/<version>.catalog.json`，不得覆盖或删除旧 catalog。manager
   只从签名 app bundle 读取 trust-history，不能信任 user-writable plugin 旁的 metadata。
   不得手工编辑生成 artifact、运行时下载 shader 或改成 unpinned upstream。

---

## 3. 一次性设置

```bash
cd /path/to/iina-magnet
git remote add upstream https://github.com/iina/iina.git   # 已加过则跳过
git fetch upstream --tags
```

---

## 4. 跟进某个上游发布（推荐用脚本）

**用脚本（推荐）**：

```bash
./scripts/sync-upstream.sh v1.4.3
```

脚本会：检查工作区干净 → fetch 上游 → 从 `develop` 开 `sync/upstream-v1.4.3` 分支
→ 合并该 tag。无冲突则自动跑验证（重拉 dylib + `swift test` + 整 app 编译）；
有冲突则列出冲突文件并停下，等你解决后用 `./scripts/sync-upstream.sh --verify` 继续验证。

**纯手动**（脚本只是把它自动化）：

```bash
git fetch upstream --tags
git checkout develop
git checkout -b sync/upstream-v1.4.3
git merge --no-edit v1.4.3          # 跟“发布 tag”，不要跟 master
# → 解决 §2-B 那几个文件的冲突
```

> **务必跟发布 tag，别跟 `master`**：master 常含半成品，既不稳定又增加冲突。

---

## 5. `project.pbxproj` 冲突的兜底办法

工程文件冲突很难手工合。最省事：

1. 冲突时该文件**整体采用上游版本**：`git checkout --theirs iina.xcodeproj/project.pbxproj`（merge 时 `theirs` = 被合入的上游）。
2. 打开 `iina.xcodeproj`，**File ▸ Add Package Dependencies… ▸ Add Local…**，选仓库根的 `iina-magnet` 目录，把 `IinaMagnet` 库链接到 **iina** target。
3. 确认 `iina/IinaMagnetBridge.swift` 和 `iina/BundledPluginManager.swift` 都仍在 iina
   target 的编译列表里（不在就拖回去）。
4. 恢复 **Copy Default Plugins** phase：绑定 Anime4K input/output `.xcfilelist`，执行
   builder `--check`，复制 archive + current catalog + trust-history，并分别用 `cmp` 验证 built resources。
5. `git add iina.xcodeproj/project.pbxproj`，继续。

---

## 6. 合并后验证（脚本会自动跑）

```bash
PROJECT_NAME=iina-magnet bash other/download_libs.sh --skip-plugins   # 上游可能换了 mpv/dylib，必须重拉
PYTHONDONTWRITEBYTECODE=1 python3 scripts/build-anime4k-plugin.py --check
node --test deps/plugins-src/anime4k/tests/*.test.js
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py'
cd iina-magnet && swift test --disable-sandbox --filter BundledPlugin && swift test && cd ..
xcodebuild -scheme iina -configuration Debug -derivedDataPath /tmp/iina-dd \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build               # 整 app 编译
./scripts/run-anime4k-libmpv-probe.sh \
  --app /tmp/iina-dd/Build/Products/Debug/IINA.app \
  --output .omx/evidence/anime4k-libmpv-upstream-sync.json
```

任何 full-suite 失败都必须与合并前 fresh baseline 对比，不能因为“与 Anime4K 无关”就忽略
新增回归。自动化通过也不代表 live GUI、凭据化 PikPak 云播、x86_64 或硬件性能已验收；
发布前按 [`ANIME4K_TESTING.md`](./ANIME4K_TESTING.md) 逐项记录，缺少
硬件/账号/fixture 时必须写 `PENDING + 原因`。

验证通过后合回主线：

```bash
git checkout develop
git merge --no-ff sync/upstream-v1.4.3 -m "Merge upstream IINA v1.4.3"
git push origin develop
```

---

## 7. 易踩的坑

1. **签名 flag 不能改**：始终用 `CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO`。
   用 `CODE_SIGNING_ALLOWED=NO` 会让改写过 install name 的 dylib 签名失效，
   macOS 26 直接 SIGKILL（CODESIGNING / Invalid Page）。
2. **依赖必须重拉**：上游升级常伴随 mpv/dylib 版本变化，合并后不重跑
   `download_libs.sh` 可能闪退。
3. **SourceKit 误报**：`swift build` 干净时，编辑器里的 “Cannot find X in scope”
   多为陈旧误报，以 `swift build` 为准。
4. **PikPak 与上游无关**：PikPak 登录走网页抓取、刷新走 refresh_token，基本不依赖
   会轮换的 captcha 盐；真要改在 `iina-magnet/Sources/IinaMagnet/PikPak/PikPakConfig.swift`。
5. **不要把 build 当 live 验收**：Debug `BUILD SUCCEEDED` 只证明编译/链接和 resource
   phase；不能代替 Anime4K GUI、PikPak 真实账号、arm64/x86_64 或 GPU 性能矩阵。

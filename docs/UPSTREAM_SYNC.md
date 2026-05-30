# 跟进上游 IINA 升级（Upstream Sync）

本项目是 [iina/iina](https://github.com/iina/iina) 的私有 fork（`AnaheimEX/iina-magnet`），
在其上叠加了媒体库 + PikPak + 蜜柑计划等功能。本文是把上游新版本合并进来、
同时**完整保留本项目所有自定义功能**的标准流程。

> 当前上游最新稳定版：**v1.4.3**（用 `git ls-remote --tags upstream` 查最新）。

---

## 1. 设计原则：为什么冲突面很小

本项目 **99% 的代码都在独立的 Swift Package 目录 [`iina-magnet/`](../iina-magnet)**
（整个 `IinaMagnet` 库 + 测试 + 两个 C++ bridge target）。上游 IINA 从不碰这个目录，
所以**这部分永远不会冲突**。

真正与上游有交集的，只有少数“钩子”——都用 `// MARK: iina-magnet hook` 之类的标记标注，
集中在下面的清单里。合并时只需照顾这几处。

---

## 2. Fork 改动清单（Manifest）

> 权威做法：fetch 上游后用
> `git diff <base>...HEAD --stat`（`base` = `git merge-base HEAD upstream/master`）
> 看实际差异。下表是人工维护的快速参照。

### A. 纯新增文件（fork 独有，**不会冲突**，合并时全部保留）
| 路径 | 作用 |
| --- | --- |
| `iina-magnet/` | 全部自定义功能所在的 SPM 包（库 + 测试 + bridge） |
| `iina/IinaMagnetBridge.swift` | iina 侧实现 `IinaBridge`（播放/进度/网络选项） |
| `lib/anitomy/` | Anitomy C++ bridge 的 vendored 源（文件名解析） |
| `other/iina-magnet-link.rb` | fork 辅助脚本 |
| `.github/workflows/iina-magnet-package.yml` | 包的 CI |
| `README.iina-magnet.md`、`docs/`（本文件等） | fork 文档 |

### B. 修改了上游文件（**冲突点**，合并时需保留 hook、合上上游新代码）
| 路径 | 改了什么 | 解决冲突要点 |
| --- | --- | --- |
| `iina.xcodeproj/project.pbxproj` | 引用本地 `iina-magnet` 包、加入 `IinaMagnetBridge.swift` 等 | **最易冲突**。乱了就取上游版，再在 Xcode 里 Add Local…重挂 `iina-magnet` 包到 iina target（见 §5） |
| `iina/AppDelegate.swift` | 启动调 `IinaMagnetBootstrap.start` / 退出调 `shutdown` | 保留 `// MARK: iina-magnet hook` 那几行，其余采上游 |
| `iina/InitialWindowController.swift` | 启动页「媒体库」按钮（`setUpMediaLibraryButton`） | 同上 |
| `other/download_libs.sh` | 顶部 `PROJECT_NAME` 默认值 hook（让 fork 目录名也能跑） | 保留该 hook，其余采上游（上游常改 dylib 版本） |
| `Configs/Deployment.xcconfig` | 部署目标 macOS 14（SwiftData/库需要） | 若上游提高了部署目标取较高者；否则保留 14 |
| `.gitignore` | 追加忽略项 | 取并集 |
| `.github/workflows/ci.yml` | 视情况微调 | 取并集 |

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
3. 确认 `iina/IinaMagnetBridge.swift` 仍在 iina target 的编译列表里（不在就拖回去）。
4. `git add iina.xcodeproj/project.pbxproj`，继续。

---

## 6. 合并后验证（脚本会自动跑）

```bash
PROJECT_NAME=iina-magnet bash other/download_libs.sh --skip-plugins   # 上游可能换了 mpv/dylib，必须重拉
cd iina-magnet && swift test && cd ..                                 # 自定义库回归（应 160+ 全绿）
xcodebuild -scheme iina -configuration Debug -derivedDataPath /tmp/iina-dd \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build               # 整 app 编译
```

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

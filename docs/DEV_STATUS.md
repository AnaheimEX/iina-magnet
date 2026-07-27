# 当前开发状态

> 唯一的项目状态入口。只记录当前代码、当前验证结果和下一步阻塞项，不保留历史提交流水账。
>
> 更新时间：2026-07-14

## 代码快照

- 分支：`develop`
- 基线提交：`8216f78b`
- 工作树：包含尚未提交的媒体库、Mikan、PikPak 与 bundled Anime4K 改动；整理前禁止按
  单一功能批量回滚或执行 `git clean -fdX`。
- 主业务代码：`iina-magnet/Sources/IinaMagnet/`
- IINA host 接入：`iina/`、`iina.xcodeproj/project.pbxproj`
- Anime4K 插件源码：`deps/plugins-src/anime4k/`
- Anime4K 可重复构建产物：`deps/plugins/anime4k.*`

## 当前已实现

### 媒体库 / Mikan / PikPak

- 本地媒体扫描、匹配、归档、标签、筛选、播放进度与手工修正。
- 媒体库网格、列表右键菜单及详情页均可“从媒体库移除”；操作带二次确认，只删除数据库记录，
  不删除磁盘源文件。源文件仍在扫描目录时，后续扫描可能重新添加。
- Mikan 浏览、登录 Cookie 持久化、magnet/torrent 捕获与保存到 PikPak。
- PikPak 网页登录、token 刷新、目录浏览、云播、离线下载、任务中心与缓存。
- 播放窗口默认记住上次用户调整后的大小与位置；显式 mpv geometry 和用户选择的自动缩放策略仍优先。

### Bundled Anime4K 1.0.2

- 插件随 App 离线打包，新安装默认 `Off`。
- Fast/HQ 均提供 A、B、C、A+A、B+B、C+A 六种 preset。
- 修复 IINA 文件 API 编码名：shader 与 marker 回读统一使用 `utf8`，不再把正确文件误判为
  损坏并让 Mode 永久停留在 Off。
- preset、Quality、Auto Apply、快捷键与提示状态持久化。
- 侧栏采用社区 `yorkyang2333/iina-anime4k` 的视觉层级与样式，并保留本项目的 Repair、
  Diagnostics 与快捷键维护功能。
- `glsl-shaders` 只移除精确的 Anime4K-owned 路径，保留其他 shader 及顺序。
- package、catalog、trust history、shader SHA-256 与完整安装树均离线验证。
- 托管安装支持 fresh install、升级、损坏恢复、禁用保持、冲突 fail-off 与事务恢复。
- 性能遥测只警告、不自动切换模式；Diagnostics 不宣称 shader pass timing。

## 当前验证结果

| Gate | 当前结果 | 说明 |
| --- | --- | --- |
| Anime4K Node tests | `61/61 PASS` | preset、完整性、runtime、UI、快捷键、遥测 |
| Repository Python tests | `57/57 PASS` | package/catalog/source contracts/timer lifecycle/window+library UI contracts |
| Swift `--filter BundledPlugin` | `39/39 PASS` | policy、transaction、resolver、完整树验证 |
| deterministic builder | `PASS` | `scripts/build-anime4k-plugin.py --check` |
| Debug App build | `PASS` | 本机 arm64 Debug App；不是 distribution 签名证明 |
| window restore smoke | `PASS` | 960×540 调整后退出并重开，位置与尺寸一致 |
| isolated runtime smoke | `PASS` | Fast A、HQ A、Off；不是全部 preset 视觉/性能验收 |
| full Swift test | `FAIL` | 当前为 234 tests、9 issues、6 failed tests，见下节 |

### Full Swift 当前失败

`LibraryFolderStoreTests`：1 个失败测试、2 个 issue。

- security-scoped bookmark 已写入，但 SwiftPM 测试环境解析后得到 0 个 URL。
- 对应断言：`LibraryFolderStoreTests.swift:35`、`:38`。

`MikanCookiePersistenceTests`：5 个失败测试、7 个 issue。

- 当前系统的 `WKWebsiteDataStore.nonPersistent()` 测试实例没有可靠保存/回读注入的 Cookie，
  导致 restore、snapshot、reset 与慢恢复竞态测试连锁失败。
- 对应断言：`MikanCookiePersistenceTests.swift:99`、`:100`、`:120`、`:135`、`:164`、
  `:183`、`:185`。

PikPak 测试当前通过。`PikPakDriveTests.swift:408` 仍有一条 Swift Testing 宏展开编译警告，
但不计入测试 issue。

## 尚未完成的验收

- Anime4K 全部 Fast/HQ × 六种 Mode 的 GUI 视觉检查。
- 快捷键、自定义冲突、Auto Apply、Repair、Diagnostics、重启与插件禁用的完整人工 smoke。
- 真实 PikPak 登录态云播 smoke。
- arm64/x86_64 双架构矩阵、GPU 性能、温度/功耗、distribution signing/notarization。
- Full Swift 上述 9 个 issue 清零或建立可重复、可解释的环境基线。

实际操作步骤只维护在 [`ANIME4K_TESTING.md`](./ANIME4K_TESTING.md)。

## 常用验证命令

```bash
node --test deps/plugins-src/anime4k/tests/*.test.js
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py'
PYTHONDONTWRITEBYTECODE=1 python3 scripts/build-anime4k-plugin.py --check
cd iina-magnet && swift test --disable-sandbox --filter BundledPlugin
cd iina-magnet && swift test --disable-sandbox
xcodebuild -project iina.xcodeproj -scheme iina -configuration Debug \
  -derivedDataPath /tmp/iina-magnet-dd \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build
```

## 必须保持的边界

- PikPak 密码和真实凭据不得进入源码、测试 fixture、日志或开发文档。
- 不用 `git clean -fdX`：它会误删被上游 `.gitignore` 覆盖但项目需要的依赖与可信产物。
- 不删除 Anime4K 的精确 ownership fallback、state migration、marker migration 或 managed installer
  recovery；这些是升级与故障恢复边界，不是冗余代码。
- 自动化通过不等于 live GUI、真实账号、跨架构、视觉或性能已经验收。
- 上游同步时按 [`UPSTREAM_SYNC.md`](./UPSTREAM_SYNC.md) 的完整 host hook 清单复核。

## 当前文件索引

| 关注点 | 路径 |
| --- | --- |
| 媒体库核心 | `iina-magnet/Sources/IinaMagnet/Library/`、`Models/` |
| Mikan | `iina-magnet/Sources/IinaMagnet/Mikan/`、`UI/Library/MikanView.swift` |
| PikPak | `iina-magnet/Sources/IinaMagnet/PikPak/`、`UI/Library/PikPak*.swift` |
| Anime4K plugin/runtime/UI | `deps/plugins-src/anime4k/` |
| Anime4K managed core | `iina-magnet/Sources/IinaMagnet/Anime4K/` |
| Anime4K host adapter | `iina/BundledPluginManager.swift`、`iina/JavascriptPlugin*.swift` |
| 可重复构建与 probe | `scripts/build-anime4k-plugin.py`、`scripts/run-anime4k-libmpv-probe.sh` |
| SwiftData 模型 | [`schema.md`](./schema.md) |
| 上游同步 | [`UPSTREAM_SYNC.md`](./UPSTREAM_SYNC.md) |

# Anime4K 当前测试操作

> 对当前 bundled Anime4K 1.0.2 的唯一人工测试说明。历史候选记录不在仓库长期保留。
>
> 更新时间：2026-07-14

## 当前自动化基线

- Node：`61/61 PASS`
- Python：`57/57 PASS`
- Swift BundledPlugin：`39/39 PASS`
- deterministic builder：`PASS`
- Debug App build：`PASS`
- 真实隔离 runtime：Fast A、HQ A、Off `PASS`
- Full Swift：234 tests、9 issues；与 Anime4K 无关，详见 [`DEV_STATUS.md`](./DEV_STATUS.md)

自动化覆盖所有 preset 数据与切换逻辑，但目前只有 Fast A、HQ A、Off 做过真实 runtime smoke。

## 测试 App

默认交付位置：

```text
~/Applications/IINA-Magnet-Debug.app
```

这是本机 Debug/adhoc 签名测试包，不是 distribution 构建，不用于发布。

## 基础操作

1. 在 IINA **Settings → UI → On Screen Display** 中启用 OSD，并确认
   **Suppress messages for → File start** 未勾选；否则播放器会按偏好隐藏当前文件信息。
2. 启动 `IINA-Magnet-Debug.app`，打开一段本地视频，确认文件开始 OSD 正常出现。
3. 打开 IINA 的 **Plugins → Anime4K**，或打开侧栏 Anime4K tab。
4. 首次状态必须为 **Off**。
5. 选择 **Fast + A**：状态应立即变为 Fast/A，画面继续播放，不应自动回到 Off。
6. 切到 **HQ + A**：Quality 与 Mode 均应保持，不能显示成功后又回到 Off。
7. 选择 **Off**：Anime4K-owned shader 应全部移除，视频继续正常播放。

## 全部 Mode 矩阵

分别在 Fast 与 HQ 下执行：

| Quality | Modes |
| --- | --- |
| Fast | A、B、C、A+A、B+B、C+A |
| HQ | A、B、C、A+A、B+B、C+A |

每次切换检查：

- UI、Plugins 菜单和 OSD 显示同一 Quality/Mode。
- 不自动回到 Off。
- 视频继续播放，无黑屏、闪退或持续报错。
- 双 pass/HQ 只允许发出性能警告，不允许自动降级或改写选择。

## 功能 smoke

### 快捷键

- `Ctrl+0`：Off
- `Ctrl+1...6`：A、B、C、A+A、B+B、C+A
- `Ctrl+7`：Fast
- `Ctrl+8`：HQ

确认无效、重复或与 IINA/mpv 冲突的自定义 binding 不安装 accelerator，但菜单仍可用。

### Auto Apply 与重启

1. 开启 Auto Apply，选择非 Off preset，切换到另一视频；preset 应自动应用。
2. 关闭 Auto Apply，再切换视频；新文件不应自动启用 Anime4K。
3. 重启 App，检查 Mode、Quality、Auto Apply 与快捷键配置仍正确。

### Repair 与 Diagnostics

- 执行 **Repair Shader Bundle** 后，完整性状态必须健康，当前 preset 可重新应用。
- Diagnostics 应显示当前文件、Mode、fps、adverse delta、ratio、consecutive 与 frame budget。
- Diagnostics 不能被解释为 shader pass 耗时。

### Disable / rollback

1. 先选择 Off。
2. 在 IINA Plugin Settings 禁用 Anime4K。
3. 重启 App；插件必须保持 disabled，托管安装器不能擅自重新启用。

## 性能与视觉记录

性能验收至少使用同一视频、同一窗口尺寸与同一播放区间：

1. Off 预热 10 秒，记录 60 秒。
2. Fast A 预热 10 秒，记录相同 60 秒。
3. 记录 fps、adverse-frame ratio、温度/功耗与明显掉帧。
4. 再对计划使用的 HQ/双 pass 模式做同样检查。

视觉检查至少覆盖线条、文字、暗场、快速运动和高纹理场景，记录锐化光晕、振铃、闪烁、
细节抹除或其他伪影。没有实测数据时保持 `PENDING`，不得声称实时性能或画质提升。

## 测试记录模板

```text
App path/version:
macOS / Mac model / architecture:
Video / resolution / display scale:
Fast modes checked:
HQ modes checked:
Shortcut / Auto Apply / Repair / restart / disable:
Off 60s:
Fast A 60s:
Visual result:
Failures / logs:
Conclusion: PASS | FAIL | PENDING
```

# IINA Cloud · PikPak + Mikan

通过插件及其随附的 macOS 原生组件，在[官方 IINA](https://iina.io) 中浏览完整蜜柑网页、
将资源保存到 PikPak，并播放云盘视频。

**[English](README.md)** · [安装](#安装) · [构建](#构建) · [架构](#架构)

这是独立、非官方的插件项目，不包含或修改 IINA 主程序。此仓库曾用于维护个人 IINA
魔改版；当前目录和提交历史只保留云播插件及其原生组件，不再包含 Anime4K 或旧媒体库。

> 1.1.0 是本地开发构建：原生组件已编译、插件已打包，但尚未使用真实账号验证完整的
> 登录、保存、播放流程或性能。随附 App 使用本地临时签名，未使用 Developer ID 签名或公证。

## 功能

- **完整蜜柑网页**：在独立、可调整大小的原生 `WKWebView` 窗口中显示网页、图片、导航和资源详情。
- **保存并云播**：捕获磁力链接，确认保存至 PikPak，并在插件管理的 IINA 播放窗口中打开可播放文件。
- **PikPak 网盘**：通过官方网页登录，在原生组件中浏览目录、视频和离线任务。
- **登录持久化**：令牌保存至本机 macOS 钥匙链，网页状态由 WebKit 持久保存；按需刷新令牌，保留账号切换和退出登录隔离。
- **提前准备**：磁力链接确认窗口打开后准备认证、查找目标目录；确认前不创建云盘任务。
- **分阶段等待**：初期缩短就绪轮询间隔，随后退避；保留超时、取消和账号状态检查。
- **播放器确认**：区分任务创建、文件可播放和 IINA 的 `iina.file-loaded` 事件，不将启动命令成功当成播放成功。
- **后台缓存**：请求直接起播，后台预读最多 60 秒、前向缓存上限 256 MiB；不由网页额外重复下载视频。
- **系统代理**：原生组件使用 macOS 网络设置，并将系统显式 HTTPS 代理传给 mpv 用于云播。

这些设置用于减少不必要等待，不保证固定起播时间，也不能消除 PikPak 任务处理、账号限制或网络条件造成的延迟。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 播放器 | 官方 IINA 1.5，启用插件 |
| 系统 | macOS 14 及以上 |
| 随附二进制 | Apple Silicon / arm64 |
| 账号 | 用户自己的 PikPak 账号 |
| 源码构建 | Xcode 命令行工具、Swift 6 或更高版本 |

插件使用 IINA 公开 API。后续 IINA 版本能否使用取决于 API 兼容性，不代表已经适配或验证所有未来版本。
当前安装包不包含 Intel 二进制。

## 安装

1. 下载 [pikpak-mikan-1.1.0.iinaplgz](https://github.com/AnaheimEX/iina-magnet/raw/refs/heads/develop/dist/pikpak-mikan-1.1.0.iinaplgz)。
2. 在 IINA **设置 → 插件** 中安装本地插件包并启用。
3. 允许声明的 **file-system** 权限，用于启动随附原生组件，以及在插件私有目录中交换播放请求。
4. 从插件菜单打开 **PikPak 网盘** 或 **蜜柑计划**。
5. 在 PikPak 窗口登录，再使用蜜柑页面的保存或保存并播放操作。

原生组件位于插件包内部，不需要替换 `/Applications` 下的 IINA。由于组件具有独立的应用与签名身份，
首次使用可能需要重新登录或授权钥匙链访问。macOS 可能限制未公证的本地构建。
公开分发应采用稳定的 Developer ID 签名并公证；本仓库不要求关闭系统安全保护。

更新时通过 IINA 安装新版插件包；停用或卸载同样在插件设置中完成。登录信息和 WebKit 数据由原生组件管理，
卸载插件不代表所有账号数据已经清除。需要结束账号会话时，请使用组件内的退出登录功能。

## 架构

```text
官方 IINA
  └─ JavaScript 插件（公开插件 API）
       ├─ 菜单入口与专用播放窗口
       ├─ 播放、缓存与代理参数
       └─ 私有文件通信
            └─ IINA Cloud.app
                 ├─ AppKit + SwiftUI 原生窗口
                 ├─ WebKit：蜜柑网页与 PikPak 网页登录
                 ├─ PikPak 认证、目录与离线任务
                 └─ 钥匙链 + WebKit 持久化数据
```

JavaScript 层通过 macOS `open` 启动组件，使用私有文件交换请求与确认；不运行本地 HTTP 服务器，
不依赖 IINA 应用源码、修改过的播放器或播放器私有 API。

Swift 云服务模块保留内部名称 `IinaMagnet`，它是原生组件代码，不是 IINA 主程序。
现有相关测试保留在 `native/Tests`；仓库工作流仅支持手动触发，本次仓库转换没有运行该工作流。

### 从磁力链接到播放

1. 原生蜜柑网页窗口捕获磁力链接并显示确认操作。
2. 提前准备认证和已有目标目录，这一步不创建云盘任务。
3. 用户确认后创建或解析 PikPak 离线任务，沿用已有任务、目录和文件定位逻辑。
4. 以较短间隔开始检查文件是否就绪，逐步增加至两秒；保留原有 90 秒就绪等待上限、取消和账号检查。
5. 将解析出的 HTTPS 媒体地址交给插件，由 IINA 播放窗口应用缓存及代理参数。
6. 等待 IINA 的文件加载确认。取消本地播放请求不会删除 PikPak 已经接受的云端任务。

### 登录信息与隐私

钥匙链本身就是**本机加密存储**。账号访问令牌和刷新令牌存入钥匙链，新建条目限定本机、不通过 iCloud 同步；
网页 Cookie 和网站存储由 WebKit 单独管理。钥匙链写入失败会提示，不再把新令牌降级写入明文偏好设置。
当前应用可访问的旧明文兼容数据，仅在安全迁移成功后删除。

JavaScript 插件不接收账号令牌或 Cookie。通信目录权限为 `0700`，原生组件写入文件的权限为 `0600`。
签名媒体链接属于临时播放数据，在通信完成后从通信文件中删除；IINA 自身的历史记录和日志行为仍然适用。
请勿在公开问题反馈中附带签名链接、Cookie、令牌或账号资料。

### 代理分流

网页及 API 使用 macOS 网络配置；播放阶段读取系统显式 HTTPS 代理，并作为 HTTP 代理传给 mpv。
此通信层不解析 PAC 文件，也不转换仅 SOCKS 的代理配置。

Surge 用户可用自己的新加坡、香港策略创建 `IINA Cloud` 选择组，然后添加：

```ini
DOMAIN-KEYWORD,pikpak,IINA Cloud
DOMAIN-SUFFIX,mikanani.me,IINA Cloud
DOMAIN-SUFFIX,mikanime.tv,IINA Cloud
```

必须先建立策略组。插件不包含订阅地址、代理节点或个人 Surge 配置；新加坡与香港是可选线路，不是经过测速的速度排名。
实际媒体 CDN 域名可能需要按播放地址和本机代理配置补充分流规则。

## 目录结构

```text
plugin/          IINA 插件清单与 JavaScript 入口
native/          随附原生组件的 Swift 包
  Companion/     App 元信息
  Sources/       网页窗口、认证、云服务与播放通信
  Tests/         现有包测试
dist/           可安装插件包
.github/         手动原生包工作流
LICENSE          GPL-3.0 许可证
```

生成的 `plugin/companion/` 目录不纳入版本控制；已提交的 `.iinaplgz` 包包含安装所需的原生程序和资源。

## 构建

克隆仓库，也可通过 GitHub **Code → Download ZIP** 下载源码：

```sh
git clone https://github.com/AnaheimEX/iina-magnet.git
cd iina-magnet
```

在 macOS 上，从仓库根目录构建和组装组件：

```sh
swift build --package-path native -c release --product IINACloud
PRODUCTS="$(swift build --package-path native -c release --show-bin-path)"
APP="plugin/companion/IINA Cloud.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/IINACloud" "$APP/Contents/MacOS/IINACloud"
cp native/Companion/Info.plist "$APP/Contents/Info.plist"
ditto "$PRODUCTS/IinaMagnet_IinaMagnet.bundle" \
  "$APP/Contents/Resources/IinaMagnet_IinaMagnet.bundle"
codesign --force --sign - --timestamp=none "$APP"
```

该命令使用本地临时签名，不包含公证，也不生成 Intel 或通用二进制；SwiftPM 默认按构建机器架构生成程序。
先删除同路径旧包，再打包插件：

```sh
mkdir -p dist
rm -f dist/pikpak-mikan-1.1.0.iinaplgz
(cd plugin && zip -qry ../dist/pikpak-mikan-1.1.0.iinaplgz \
  Info.json README.md LICENSE global.js main.js companion)
```

发布更新时保持插件清单、原生组件版本号和安装包文件名一致。构建与打包成功不等于真实账号云播已经通过验证。

## 参与贡献

修改范围请聚焦云播插件和原生组件。反馈问题时提供 IINA、macOS、插件版本、触发操作和脱敏错误信息，
不要上传账号凭据或私人媒体链接。需要时可主动运行现有测试：`swift test --package-path native`；
这些测试不代表真实账号或性能验证。

## 许可证与致谢

[GPL-3.0](LICENSE)，保留已有版权与许可证声明。
IINA 是由 [iina/iina](https://github.com/iina/iina) 维护的独立项目；PikPak 和蜜柑是第三方服务。
本插件不隶属于上述服务，也不代表其运营方或 IINA 项目背书。请使用自己的账号及有权访问的内容。

# Issue 19 · README 用户文档（订阅指南、规则指南、法律免责）

Status: ready-for-agent
Sprint: 5 (验收)
Created: 2026-05-26
Updated: 2026-05-26
Related: PRD §Further Notes "用户文档"
BlockedBy: 14, 15, 17

## 描述

Phase 1 release 前更新 `README.md`，从工程文档升级为面向用户的入门指南。原有"文档地图"挪到 `docs/README.md`。

## 验收标准

- [ ] README.md 顶部加：
  - 项目截图（RSS Manager + BT Manager 各 1 张）
  - "下载安装" 段（GitHub Releases 链接）
- [ ] "快速开始"段：
  - 安装 → 首次启动 disclaimer → 添加第一个订阅 → 配置第一条规则 → 等待命中 → 双击播放
  - 配步骤截图
- [ ] "如何添加订阅源" 完整教程：
  - 公开 RSS 例子（nyaa.si）
  - 登录态 RSS 例子（mikanani.me 的 MyBangumi）
    - 子段：怎么从浏览器拿 Cookie（Chrome / Safari / Firefox 各一步骤）
    - 警告：Cookie 是敏感数据，别在 issue 截图里贴
- [ ] "如何写规则" 教程：
  - include / exclude 示例（"我只要 1080p 简体中文字幕"）
  - regex 进阶（"只要 S01 第 1-12 集"）
  - 常用关键词模板：
    - 简中：`简`、`CHS`、`SC`、`简中`、`简日`
    - 繁中：`繁`、`CHT`、`TC`
    - 双语：`简日`、`简英`、`双语`
    - 1080p / 4K / 2160p / WEB-DL / BDRip
    - 字幕组：LoliHouse / Nekomoe kissaten / 喵萌奶茶屋 / SweetSub …
- [ ] "法律免责" 段（与 Disclaimer.md 同步）
- [ ] "Troubleshooting"：
  - RSS 拉取失败：检查 cookie 是否过期
  - BT 不下载：检查端口是否被防火墙阻
  - 边看边播卡顿：bitrate 估算调高 / 关闭其他 BT 任务
- [ ] "已知限制"：
  - 不支持 iOS / iPadOS
  - 不内置 tracker
  - 默认零做种（设置可改）
- [ ] 中英双语 README（README.md 中文为主 + 顶部 "English version" 链接到 README.en.md）
- [ ] License、Acknowledgements（iina / libtorrent / Anitomy）

## 实现提示

- 截图工具：macOS 内置 cmd+shift+5；标注用 Annotate 或 Skitch
- 项目 logo（如要做）作为 Phase 1 的 nice-to-have

## Out of scope

- 视频教程
- 多语言（除 zh-CN/en 外）

## Comments

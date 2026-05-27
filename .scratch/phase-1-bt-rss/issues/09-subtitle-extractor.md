# Issue 09 · SubtitleExtractor 深模块

Status: completed (merged to develop)
Sprint: 2 (边看边播)
Created: 2026-05-26
Updated: 2026-05-26
Related: PRD §IM-7, US-33..37
BlockedBy: 06
Blocks: 17

## 描述

torrent 下载完成后，扫描下载目录，识别字幕文件，匹配到对应视频，复制到视频同目录的 sidecar 路径（同基名 + 语言代码 + 扩展名），让 mpv 自动加载。

**纯函数式深模块**：input = 目录路径，output = `[(video, subs)]` 计划；执行（文件复制）走 thin wrapper。

## 验收标准

- [ ] `iina-magnet/Sources/IinaMagnet/Subtitles/SubtitleExtractor.swift`
- [ ] API（plan 与 execute 分离）：
  ```swift
  struct SubtitleExtractionPlan: Sendable, Equatable {
      let video: URL
      let copies: [SubtitleCopy]   // 每个字幕的复制计划
  }
  struct SubtitleCopy: Sendable, Equatable {
      let source: URL
      let destination: URL         // <videoDir>/<videoBasename>.<lang>.<ext>
      let detectedLanguage: String // BCP-47, "und" 未识别
  }

  struct SubtitleExtractor {
      static func plan(rootDirectory: URL) throws -> [SubtitleExtractionPlan]
      static func execute(_ plans: [SubtitleExtractionPlan], using fs: FileSystemAccessor) throws
  }
  ```
- [ ] 支持扩展名：`.srt`, `.ass`, `.ssa`, `.vtt`, `.sub`(+`.idx` 双文件), `.sup`
- [ ] 视频扩展名集合：`.mkv`, `.mp4`, `.m4v`, `.mov`, `.avi`, `.ts`, `.m2ts`, `.flv`, `.webm`
- [ ] 字幕→视频匹配：
  - 优先匹配同基名（不区分语言后缀）
  - 次匹配同目录最近邻（同目录中视频文件数 ≤ 字幕文件数 → 按集数编号匹配）
  - 再匹配子目录字幕（如 `Subs/01/sc.ass`）→ 根据集数序号挂到同集视频
- [ ] 语言识别（按 PRD §IM-7 启发式表）
- [ ] 单元测试 ≥ 90% 覆盖：
  - 单视频单字幕（同基名）
  - 单视频多语言字幕
  - 多集字幕在 Subs/ 子目录中按集数挂载
  - `.sub`+`.idx` 双文件作为一组复制
  - 不识别语言时 fallback `und`
  - 已存在同名 sidecar → 不覆盖（生成 `.1.ext` 后缀避免覆盖）
- [ ] `FileSystemAccessor` 协议化便于测试 mock；生产实现走 `FileManager`

## 实现提示

- 用 `URL.standardizedFileURL.lastPathComponent` 与 `URL.deletingPathExtension`
- 集数序号提取：先用 Anitomy（Issue 后置），暂时用 regex `S(\d+)E(\d+)` 与 `\b(\d{1,3})\b`
- 文件复制用 `FileManager.copyItem`，不要 hard link（用户可能跨卷）

## Out of scope

- Anitomy 集成（Phase 2 issue 引入）
- 在线字幕搜索

## Comments

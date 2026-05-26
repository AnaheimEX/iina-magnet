# Issue tracker: Local Markdown

Issues 与 PRD 在本仓库以 markdown 文件形式存放在 `.scratch/`。

## 目录约定

- 一个功能一个目录：`.scratch/<feature-slug>/`
- PRD：`.scratch/<feature-slug>/PRD.md`
- 实施 issue：`.scratch/<feature-slug>/issues/<NN>-<slug>.md`（从 `01` 编号）
- 已发布版本的 PRD 同步副本可放到 `docs/<phase>/PRD.md`（如 `docs/phase-1/PRD.md`）

## Issue 文件格式

```markdown
# <issue 标题>

Status: <triage-label>
Assignee: <agent-name | human-name | unassigned>
Created: <YYYY-MM-DD>
Updated: <YYYY-MM-DD>

## 描述

<问题描述>

## 验收标准

- [ ] ...
- [ ] ...

## Comments

### YYYY-MM-DD <author>
<comment>
```

## 当 skill 说"发布到 issue tracker"

在 `.scratch/<feature-slug>/` 下新建文件（如目录不存在则一并创建）。

## 当 skill 说"获取相关 ticket"

读取被引用的文件路径。用户通常会直接给出路径或 issue 编号。

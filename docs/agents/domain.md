# Domain Docs

mattpocock engineering skills 在探索代码库前应当先读领域文档。

## 探索前先读

- **`CONTEXT.md`**（仓库根）—— 领域词汇表
- **`docs/adr/`** —— 与你正在改的领域相关的 ADR

文件不存在时**静默继续**，不要建议用户立刻补全。`/grill-with-docs` 会在术语真正出现时按需创建。

## 仓库布局

Single-context 仓库：

```
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-fork-iina-gpl3.md
│   ├── 0002-libtorrent-inproc.md
│   ├── 0003-swiftdata-persistence.md
│   ├── 0004-swiftui-independent-windows.md
│   └── 0005-multi-source-metadata.md
└── iina-magnet/
```

## 使用词汇表的措辞

输出涉及领域概念时（issue 标题、重构提案、假设、测试名），**使用 CONTEXT.md 中定义的术语**，不要漂移到其他同义词。

新概念若不在词汇表中：要么是发明了项目不使用的语言（重新考虑），要么是真正的语义缺口（标记给 `/grill-with-docs`）。

## ADR 冲突要明确标出

若你的输出与已有 ADR 冲突，主动指出：

> _与 ADR-0002 冲突——但理由是…_

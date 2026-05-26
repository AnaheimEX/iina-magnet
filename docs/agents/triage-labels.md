# Triage Labels

mattpocock skills 内部使用五种标准 triage role；本仓库使用默认映射。

| 角色 in skills | 本仓库 label | 含义 |
| --- | --- | --- |
| `needs-triage` | `needs-triage` | 维护者需要评估 |
| `needs-info` | `needs-info` | 等待报告者补充信息 |
| `ready-for-agent` | `ready-for-agent` | 完全规格化，AFK agent 可直接接手 |
| `ready-for-human` | `ready-for-human` | 需要人类实现 |
| `wontfix` | `wontfix` | 不会处理 |

在本地 markdown issue 中，label 写在文件头 `Status:` 字段。

## 状态机

```
未提交 → needs-triage → needs-info ↺
                     → ready-for-agent → (实现) → 完成
                     → ready-for-human → (实现) → 完成
                     → wontfix （归档，不删除）
```

`needs-info` 之后可循环回到 `needs-triage`。`wontfix` 与 `完成` 是终态。

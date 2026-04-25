---
name: session-queue
description: 管理 Session 反馈优化队列
---

管理用户提交的 Session 反馈优化队列。

**用法**：
- `/session-queue` — 查看活跃队列
- `/session-queue resume <convId>` — 获取恢复分析的命令
- `/session-queue complete <convId>` — 标记反馈为已完成

## 执行步骤

解析 `$ARGUMENTS`：

| 参数 | 动作 |
|------|------|
| 空 或 `list` | 扫描 `$PROJECT_DIR/data/optimization_log/` 列出待处理的优化记录 |
| `resume <convId>` | 查找该 convId 的分析会话，告知用户如何恢复 |
| `complete <convId>` | 将对应的优化记录标记为已完成（在文件中更新状态） |

> 如果项目有专门的队列管理脚本（如 `scripts/feedback-queue.js`），优先使用脚本执行上述操作。

---
name: session-queue
description: 管理 Session 反馈优化队列
---

管理用户提交的 Session 反馈优化队列。

**用法**：
- `/session-queue` — 查看活跃队列
- `/session-queue resume <convId>` — 获取恢复分析的命令
- `/session-queue complete <convId>` — 标记反馈为已完成

参数 `$ARGUMENTS` 是子命令和参数。

**执行步骤**：

1. 解析 `$ARGUMENTS`：
   - 空 或 `list` → 查看队列
   - `resume <convId>` → 恢复分析
   - `complete <convId>` → 标记完成

2. **查看队列**：
   ```bash
   node $PROJECT_DIR/scripts/feedback-queue.js list
   ```

3. **恢复分析** (`resume <convId>`)：
   - 查找该 convId 的 `claude_session_id`
   - 告知用户运行 `claude -r <session-id>` 恢复分析会话

4. **标记完成** (`complete <convId>`)：
   ```bash
   node $PROJECT_DIR/scripts/feedback-queue.js complete <convId>
   ```

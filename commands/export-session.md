---
name: export-session
description: 导出指定会话的完整分析报告
---

将指定会话的完整内容导出为结构化 Markdown 分析文档。

**用法**：`/export-session <conversation_id>`

参数 `$ARGUMENTS` 是会话 ID（数字）。

**执行步骤**：

1. 从 `$ARGUMENTS` 中提取会话 ID（如果未提供或不是数字，提示用户输入）
2. 运行导出脚本：
   ```bash
   node $PROJECT_DIR/scripts/export-session.js <conversation_id>
   ```
3. 脚本会自动：
   - 从数据库读取会话的所有消息（用户/Agent）
   - 查询完整工具调用记录
   - 从日志提取该会话的完整日志
   - 提取工具调用链（工具名、输入、结果、是否失败）
   - 加载 Agent 配置快照（model、tools、安全规则等）
   - 生成结构化 Markdown 报告
4. 输出文件位置：`$PROJECT_DIR/data/session_cases/conv-<id>.md`
5. 告诉用户导出结果（文件路径、消息数、工具调用数、日志行数）

**报告包含**：
- 概要：用户、时间、消息数、工具调用统计、费用、耗时、最终状态
- Agent 配置快照
- 工具调用统计：按工具分类汇总 + 失败调用详情
- 对话流程：每轮对话的用户消息 + Agent 工具调用链 + 回复内容

**下游用途**：
- `/optimize-session <id>` — 基于导出报告进行分析
- `/replay-session <id>` — 重放会话验证优化效果

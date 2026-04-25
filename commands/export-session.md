---
name: export-session
description: 导出指定会话的完整分析报告
---

将指定会话的完整内容导出为结构化 Markdown 分析文档。

**用法**：`/export-session <conversation_id>`

参数 `$ARGUMENTS` 是会话 ID。

## 执行步骤

1. 从 `$ARGUMENTS` 中提取会话 ID（如果未提供，提示用户输入）
2. 使用项目的会话导出工具生成报告。导出工具应产出包含以下内容的 Markdown 文件：
   - 概要：用户、时间、消息数、工具调用统计、费用、耗时、最终状态
   - Agent 配置快照（model、tools、安全规则等）
   - 工具调用统计：按工具分类汇总 + 失败调用详情
   - 对话流程：每轮对话的用户消息 + Agent 工具调用链 + 回复内容
3. 输出文件位置：`$PROJECT_DIR/data/session_cases/conv-<id>.md`
4. 向用户报告导出结果（文件路径、消息数、工具调用数）

**下游用途**：
- `/optimize-session <id>` — 基于导出报告进行分析
- `/replay-session <id>` — 重放会话验证优化效果

> 项目需要实现自己的会话导出脚本（如 `scripts/export-session.js`），负责从数据库读取会话数据并生成上述格式的 Markdown 报告。

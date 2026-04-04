---
name: optimize-session
description: 从第一视角还原 Agent 决策路径，审视上下文工程结构，生成长期价值导向的优化方案
---

分析会话 `$ARGUMENTS`（会话 ID，数字）。

1. 确保报告存在：检查 `$PROJECT_DIR/data/session_cases/conv-<id>.md`，不存在则运行 `node $PROJECT_DIR/scripts/export-session.js <id>` 生成
2. 读取 `skills/session-optimizer/SKILL.md` 获取完整方法论
3. 按 SKILL.md 工作流执行（理解 Agent → 第一视角还原 → 从案例到结构 → 产出）

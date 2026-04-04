---
name: cross-analyze
description: 跨 Session 模式分析，识别共性问题趋势
---

对多个 Session 分析报告进行跨会话模式分析，识别系统性问题和退化趋势。

**用法**：`/cross-analyze`

**执行步骤**：

1. **收集素材**：
   - 扫描 `$PROJECT_DIR/data/session_cases/conv-*.md`，列出所有已有的分析报告
   - 扫描 `$PROJECT_DIR/data/optimization_log/opt-*.md`，列出所有优化记录

2. **提取硬指标**：
   对每个会话报告，运行：
   ```bash
   node $PROJECT_DIR/scripts/extract-metrics.js <convId>
   ```

3. **读取方法论**：
   读取 `skills/session-optimizer/SKILL.md` 中趋势分析的方法论作为分析框架。

4. **跨 Session 分析**：
   综合所有素材，识别以下模式：
   - **重复工具失败**：同一工具在多个 session 中反复失败的模式
   - **路由退化趋势**：路由步骤数随时间增加/波动的趋势
   - **重复用户投诉主题**：多个用户反馈中出现的共性问题描述
   - **优化效果验证**：已实施的优化是否在后续 session 中生效
   - **指标异常值**：与历史基线偏差较大的 session

5. **输出报告**：
   生成跨会话分析报告，包含：
   - 分析覆盖范围（N 个 session，时间跨度）
   - 共性问题排名（按影响频次排序）
   - 趋势图表（文本格式的指标变化趋势）
   - 优先修复建议（按 ROI 排序）
   - 各 session 指标对比表

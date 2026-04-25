---
name: replay-session
description: 重放指定会话验证优化效果，生成对比报告
---

AI 驱动的智能 Replay 验证——不再机械重放所有用户消息，而是理解优化内容、综合 prompt、评估结果、回填预测验证。

**用法**：`/replay-session <conversation_id>`

参数 `$ARGUMENTS` 是会话 ID（数字）。

---

## Phase 1: 加载优化上下文

1. 从 `$ARGUMENTS` 提取会话 ID
2. 读取以下文件：
   - `$PROJECT_DIR/data/optimization_log/opt-<id>.md` — 优化记录（改了什么、预测了什么）
   - `$PROJECT_DIR/data/session_cases/conv-<id>.md` — 原始会话报告
   - `$PROJECT_DIR/data/session_cases/conv-<id>-metrics.md` — 原始硬指标
3. 如果 `opt-<id>.md` 不存在，警告用户先运行 `/optimize-session <id>`，然后停止

---

## Phase 2: 设计 Replay 策略

系统性分析后输出策略摘要供用户审阅。

### a) Prompt 综合

从原始会话报告中：
- 提取**第一条用户消息**作为 prompt 基础
- 扫描后续轮次的用户消息，区分两类：
  - **补充说明**（合并入 prompt）：用户提供了额外上下文、文件路径、约束条件等——这些是原始问题的一部分
  - **纠错**（丢弃）：用户指出 Agent 犯了错误让它重做——这些是对旧行为的修正，新 Agent 不会犯同样的错
- 如有附件信息，保留
- 综合生成一个完整的 replay prompt

如果综合后 prompt >= 500 字符，写入临时文件 `$PROJECT_DIR/data/session_cases/.replay-prompt-<id>.tmp`（Phase 3 用 `--prompt-file`）。
如果 < 500 字符，Phase 3 直接用 `--msg`。

### b) 成功标准

从 `opt-<id>.md` 中：
- 找到"预测"相关章节（如"可证伪预测"、"预期改善"等）
- 提取每个具体的可证伪预测（如"工具调用数从 45 降到 30 以下"）
- 转换为 replay 后可检查的指标

### c) 输出策略摘要

以下面格式输出给用户审阅：

```
## Replay 策略

### 原始会话概况
- N 轮对话，其中 M 轮为用户纠错
- 核心问题：[一句话]

### 设计的 Replay Prompt
[综合后的 prompt，标注了从后续轮次合并的内容]

### 成功标准（来自优化记录预测）
1. [指标]: [当前值] → [预测值]
2. ...

### 期望行为
- [定性描述]
```

**等待用户确认后再继续。** 用户可能修改 prompt 或调整标准。

---

## Phase 3: 执行 Replay

根据 prompt 长度选择调用方式：

使用项目的 replay 工具执行重放。Replay 工具应支持：
- 指定会话 ID 和目标轮次（默认第 1 轮）
- 传入综合后的 prompt（通过参数或临时文件）
- 输出结构化 JSON 结果和对比报告

```bash
# 示例（根据项目实际的 replay 工具调整命令）
# 短 prompt：直接传参
replay-tool <id> --turn 1 --msg "prompt text"
# 长 prompt：通过临时文件
replay-tool <id> --turn 1 --prompt-file <temp-file>
```

**执行策略**：使用 `Bash` 工具的 `run_in_background: true` 启动 replay。完成时系统会自动通知，无需轮询——直接继续 Phase 4。

执行完后**删除临时 prompt 文件**（如果有）。

---

## Phase 4: 评估结果

### a) 读取输出

- 读取 replay 工具产出的结构化 JSON 数据（含 `metrics` 字段）
- 读取 replay 工具产出的对比报告（Markdown 格式）

### b) 硬指标对比

从 replay JSON 的 `metrics` 字段提取：
- `totalToolCalls`、`totalErrors`、`totalCost`、`totalDurationMs`
- `toolCallsByName`（各工具调用次数分布）
- `bashWriteCount`、`fileReadSequence`

将每个值与 opt record 中的预测逐一对比，判定每个预测"命中"还是"未命中"。

### c) 语义质量评估

- 阅读 replay 的 Agent 回复内容（JSON 中的 `content` 字段）
- 对照原始会话报告中 Agent 最终（纠正后的）正确回复
- 评估：事实正确性、完整性、路由效率（是否一次做对）

### d) 判断是否需要跟进

如果 Agent 回复中有"请提供更多信息"或明显遗漏关键内容：
- 可决定发送一条跟进消息
- 从 replay JSON 中提取 `sessionId`（`turns[0]` 中不含，需从脚本输出中获取）
- 使用 `--resume <sessionId> --msg "follow-up text"` 继续
- **最多 1 次跟进**，避免滑入纠错模式

---

## Phase 5: 更新记录

### a) 回填优化记录

编辑 `$PROJECT_DIR/data/optimization_log/opt-<id>.md`，在"验证结果"章节（如不存在则新增）填写：

```markdown
## 验证结果

**Replay 时间**: YYYY-MM-DD HH:MM

### 硬指标快照

| 指标 | 优化前 | 预测 | 实际(Replay) |
|------|--------|------|-------------|
| 工具调用 | X | Y | Z |
| 错误数 | X | Y | Z |
| 费用 | $X | $Y | $Z |

### 预测验证

| # | 预测内容 | 预测值 | 实际值 | 命中 |
|---|---------|--------|--------|------|
| 1 | ... | ... | ... | pass/fail |

**预测命中率**: M/N (XX%)

### 未命中分析
[如有未命中预测，分析原因]

### 语义质量
- 事实正确性: pass/fail
- 完整性: pass/fail
- 一次做对: pass/fail
```

### b) 综合评估

向用户输出最终结论：
- 整体验证结果（通过/部分通过/未通过）
- 预测命中率
- 如有未命中预测，分析可能原因并建议后续动作

---

## 前置条件

- 项目需实现 replay 工具（负责创建临时会话、发送 prompt、收集 metrics）
- 需要 API 认证配置
- 需要先运行 `/optimize-session <id>` 生成优化记录

## 注意事项

- Replay 会产生实际的 API 调用费用
- 默认只 replay 第一轮（`--turn 1`），因为智能 prompt 综合已将多轮纠错压缩为单轮
- 临时 CWD 中的 agent 行为受当前（已优化的）上下文文件影响，这正是验证的目的

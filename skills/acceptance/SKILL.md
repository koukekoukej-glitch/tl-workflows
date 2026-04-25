---
name: acceptance
description: |
  E2E 验收管线——从 plan 文件的验收场景驱动全量验收。
  在 /finish 之后、deploy.sh 之前执行，读取 plan 文件中的验收场景，
  用 Playwright + agent-browser 进行功能验收和上下文工程验收。
  手动调用 /acceptance，或在 Vibe 管线中 /finish 后调用。
  触发词：验收、acceptance、跑验收、全量验收、验收测试。
---

# E2E 验收管线

从 plan 文件的验收场景精确指导测什么。与 /finish 7b-7e 的区别：/finish 从 git diff 自动推导测什么（小流程），/acceptance 从 plan 文件读取验收场景做全量验收（大流程）。

**适用时机**：走完 brainstorm → vibe → finish 的大需求，需要在 deploy 之前做完整验收。

**打回机制**：验收失败后自动生成 fix plan，最多打回 2 轮。超过 2 轮提示用户手动介入。

---

## Phase 1: 启动 Staging

**目标**：确保 staging 环境运行最新代码，健康检查通过。

### 步骤

1. 确认 plan 文件路径。如果用户未指定，扫描 `data/todo/` 寻找包含 `### 验收场景` 区块的 plan 文件，列出供用户选择。
2. 读取 plan 文件，提取 `### 验收场景` 区块（包含「功能验收」和「上下文工程验收」两个子区块）。如果 plan 文件没有验收场景区块，报告错误并终止。
3. 重建测试环境，确保运行最新代码：

```bash
# 根据项目配置执行环境重建（如 staging rebuild、docker compose up 等）
```

4. 等待重建完成，确认健康检查通过：

```bash
curl -sf http://localhost:$TEST_PORT/api/health && echo "Test env healthy"
```

如果健康检查失败，检查测试环境日志诊断问题。最多重试 2 次，仍然失败则终止验收并报告错误。

5. 记录本轮验收的轮次编号（首次为 round=1，打回后递增）。

**完成条件**：staging 健康检查通过，plan 验收场景已解析。

---

## Phase 2: Playwright 自动化测试

**目标**：运行 plan 文件中功能验收场景对应的 E2E 测试文件，确保无回归。

### 步骤

1. 从 plan 的功能验收场景中，识别涉及的功能模块。按以下映射表确定需要运行的 Playwright 测试文件：

| 功能模块关键词 | 对应测试文件 |
|---------------|------------|
| 认证、登录、权限 | 认证相关的 spec 文件 |
| 核心业务流程 | 对应业务模块的 spec 文件 |
| API、接口 | API 测试 spec 文件 |
| 安全、注入、XSS | 安全测试 spec 文件 |

> 根据项目实际的测试文件组织方式定制映射表。

如果 plan 验收场景中明确指定了 E2E 测试文件路径，直接使用指定路径。

如果无法映射到具体文件，运行全部 E2E 测试：`npx playwright test`。

2. 运行 Playwright 测试：

```bash
npx playwright test {mapped_test_files}
```

3. **Playwright 失败 = 硬门控**。如果有测试失败：
   - 记录失败的测试名称、错误信息、截图路径
   - **不继续后续步骤**，直接跳到第 5 步决策生成 FAIL 结果

**完成条件**：所有 Playwright 测试通过。

---

## Phase 3: agent-browser 功能验收

**目标**：读取 plan 文件的「功能验收」场景，逐个用 agent-browser 操控浏览器验证，截图取证。

### 步骤

1. 从 plan 的「功能验收」区块中，逐条读取验收场景（「给定→当→则」格式）。

2. 对每条功能验收场景，执行以下操作序列：

**a. 打开并登录测试环境：**

```bash
npx agent-browser open http://localhost:$TEST_PORT
npx agent-browser wait --load networkidle
# 执行项目特定的登录流程（如 dev-login API、OAuth mock、测试账号登录等）
npx agent-browser wait --load networkidle
npx agent-browser snapshot -i
```

**b. 根据场景的「当」部分执行操作：**

使用 `snapshot -i` 获取元素引用 → `fill`/`click`/`select` 执行交互 → `wait` 等待结果。

（具体操作取决于场景描述，AI 根据场景语义选择 agent-browser 命令。）

**c. 根据场景的「则」部分验证结果：**

- 使用 `snapshot -i` 获取页面状态
- 使用 `get text @eN` 获取元素文本
- 使用 `screenshot` 截图取证
- 将实际结果与预期结果对比

**d. 记录结果：**

- PASS：场景验证通过，附截图
- FAIL：场景验证失败，附截图 + 实际结果 vs 预期结果

3. 操作完成后关闭浏览器：

```bash
npx agent-browser close
```

**完成条件**：所有功能验收场景已执行，结果已记录。

---

## Phase 4: 上下文工程验收

**目标**：读取 plan 文件的「上下文工程验收」场景，登录 staging 发送测试 prompt，通过硬检查和软检查验证 Agent 行为。

### 跳过条件

如果 plan 的「上下文工程验收」子区块内容为"不涉及"，跳过此步骤。

### 步骤

1. 从 plan 的「上下文工程验收」区块中，逐条读取验收场景，提取：
   - **测试 prompt**：要发送给 Agent 的输入
   - **硬检查项**：预期的工具调用、路由目录等客观事实
   - **软检查项**：预期回复应包含的关键信息（标准答案对比）

2. 对每条上下文工程验收场景，执行以下操作序列：

**a. 登录测试环境并进入操作界面：**

```bash
npx agent-browser open http://localhost:$TEST_PORT
npx agent-browser wait --load networkidle
# 执行项目特定的登录流程
npx agent-browser wait --load networkidle
npx agent-browser snapshot -i
```

**b. 发送测试 prompt：**

从 snapshot 中找到输入框和发送按钮的元素引用，执行：

```bash
npx agent-browser fill "@textarea_ref" "{测试 prompt 内容}"
npx agent-browser click "@send_button_ref"
```

**c. 等待 Agent 回复完成：**

```bash
npx agent-browser wait 60000
npx agent-browser snapshot -i
npx agent-browser screenshot
```

（根据实际 UI 状态判断 Agent 是否已完成回复——如出现回复内容、loading 消失等。必要时多次 snapshot 确认。）

**d. 硬检查——日志事实验证：**

读取测试环境日志，查找该会话的工具调用记录：

```bash
# 根据项目的日志路径和格式，搜索工具调用记录
grep "tool_use\|tool_call\|Tool:" <test-env-log-path> | tail -30
```

对照场景定义的硬检查项，逐一验证：
- 是否调用了预期的工具（如 Read、Bash、Grep）
- 是否路由到了预期的目录
- 是否读取了预期的文件

**硬检查失败 = 硬阻断。** 记录失败原因，标记该场景为 FAIL。

**e. 软检查——AI 回复质量评估：**

从 snapshot 或页面文本中提取 Agent 的回复内容，对照场景定义的软检查项：

1. 回复是否包含预期的关键信息
2. 回复是否体现了变更后的 rules/知识内容
3. 回复的准确性和完整性评估

**软检查是主观判断，不阻断流程。** 记录 AI 评分理由和证据（回复文本 + 截图），标记为 PASS 或 WARN。

**f. 关闭浏览器：**

```bash
npx agent-browser close
```

3. 汇总所有上下文工程验收场景的结果。

**完成条件**：所有上下文工程验收场景已执行，硬检查和软检查结果已记录。

---

## Phase 5: 决策

**目标**：汇总前四步的结果，给出最终判定，执行对应的后续动作。

### 结果汇总

| 判定 | 条件 | 处理 |
|------|------|------|
| **PASS** | Playwright 全部通过 + 功能验收全部 PASS + 上下文工程硬检查全部通过 + 软检查无明显问题 | 输出验收报告，提示可以 `bash deploy.sh` 部署 |
| **WARN** | Playwright 全部通过 + 硬检查全部通过 + 但有软检查标记为 WARN | 展示所有 WARN 证据（Agent 回复 + 截图 + 评分理由），由用户决定是否继续部署 |
| **FAIL** | Playwright 有失败 或 功能验收/上下文工程硬检查有失败 | 生成 fix plan，提示修复 |

### PASS 处理

输出验收报告：

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PASS - 验收通过
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Plan: {plan 文件名}
轮次: {round}/2

Playwright: {N}/{N} 通过
功能验收: {N}/{N} 通过
上下文工程验收: 硬检查 {N}/{N} 通过，软检查 {N}/{N} 通过

可以执行 bash deploy.sh 部署到生产。
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### WARN 处理

输出带证据的报告，列出所有 WARN 项的详情（Agent 回复摘要、截图路径、AI 评分理由），提示用户决定。

### FAIL 处理

**Step 1: 检查打回轮次**

如果 `round >= 3`（已打回 2 轮仍然失败）：
- 输出失败报告，列出所有失败项
- 提示：「已打回 2 轮仍未通过，建议手动介入排查。」
- 终止验收流程

**Step 2: 生成 fix plan**

将失败项整理为一个新的 plan 文件：

```bash
# fix plan 路径
$PROJECT_DIR/data/todo/{original-plan-name}-fix-{round}.md
```

fix plan 内容结构：

```markdown
# {原 plan 名称} - 修复轮次 {round}

**背景**：验收管线第 {round} 轮发现以下问题，需要修复后重新验收。

**进度**：未开始 0/N

## Spec

### 失败项

{逐条列出失败的验收场景、错误信息、截图路径}

### 修复建议

{基于失败原因给出的修复方向}

## 子任务

### T1: {修复任务 1} ⬚ 待开始
- **范围**：{具体修复内容}
- **验证命令**：{修复后的验证方式}

### TN: 重新验收 ⬚ 待开始
- **范围**：修复完成后，运行 `/acceptance` 重新验收（round={round+1}）
- **验证命令**：`/acceptance` PASS
```

**Step 3: 提示修复**

```
验收失败（轮次 {round}/2），已生成 fix plan：
data/todo/{original-plan-name}-fix-{round}.md

使用 /vibe run {fix-plan-name} 执行修复，完成后重新运行 /acceptance。
```

---

## 验收场景解析规则

Plan 文件中的验收场景遵循以下格式（由 /brainstorm 的 Spec 模板定义）：

### 功能验收格式

```
#### 功能验收
- 给定 {前置条件}，当 {用户操作}，则 {预期结果}
```

### 上下文工程验收格式

```
#### 上下文工程验收（如涉及 agent-cwd/ 变更）
- **测试 prompt**：{发送给 Agent 的测试输入}
  - 硬检查（工具调用/路由事实）：{预期 Agent 调用的工具、路由到的目录}
  - 软检查（标准答案对比）：{预期回复应包含的关键信息}
```

如果 plan 的上下文工程验收写的是"不涉及"，上下文工程验收步骤跳过。

---

## 注意事项

- **agent-browser 使用 `npx agent-browser` 调用**（未全局安装）
- **登录方式**：根据项目配置选择自动登录方式（dev-login API、测试 token、OAuth mock 等）
- **元素引用**：每次操作后必须重新 `snapshot -i` 获取最新的 `@eN` 引用，不要复用旧引用
- **eval 输出**：JSON 引号可能被转义，grep 匹配时用宽松模式
- **日志路径**：根据项目配置确定测试环境的日志路径
- **截图保存**：使用 `npx agent-browser screenshot` 默认保存到临时目录，用于验收报告取证

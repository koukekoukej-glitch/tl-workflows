---
name: finish
description: 提交当前改动，合并到主分支，测试并部署
---

执行完整的 worktree 完工 SOP，共七个阶段。

**断点恢复**：开始前检查 `$PROJECT_DIR/data/.finish-state`。如存在，读取内容确认上次中断的阶段，询问用户是否从断点继续。

每完成一个阶段，更新状态文件：`echo "stage:N" > $PROJECT_DIR/data/.finish-state`。全部完成后删除状态文件。

---

## 阶段一：变更审查 & 复杂度判断

运行以下命令，全面审查本次改动：

```bash
git diff main...HEAD --stat        # 文件级变更概览
git diff main...HEAD               # 完整 diff
git log main...HEAD --oneline      # commit 历史
```

**复杂度评估标准：**

| 规模 | 判断标准 | 处理方式 |
|------|---------|---------|
| 小改动 | 3 个文件以内，100 行以内，逻辑清晰 | 跳过审查，直接进入阶段二 |
| 中等改动 | 4-10 个文件，或逻辑有一定复杂度 | AI 自行判断是否执行 Codex 审查 |
| 大改动 | 10 个文件以上，或引入新模块/重构 | **执行 Codex 审查 + 修复**（见下方流程） |

**AI 自主决策**：不需要询问用户。根据上表自行判断，需要审查时按以下流程执行。

### Codex 审查 + 修复流程

**Step 1：Codex 对抗审查**

执行 `/codex:adversarial-review --scope branch --base main --effort medium --wait`

**Step 2：解析 findings**

Claude 读取 Codex 返回的自由文本 findings，判断是否存在实质性问题：
- **无实质性问题**（纯风格建议、已知的有意设计等）→ 跳过修复，直接进入阶段二
- **有实质性问题**（逻辑缺陷、安全隐患、资源泄漏、架构问题等）→ 继续 Step 3

**Step 3：Claude Fix Agent 修复**

派发 Claude Fix Agent（`Agent` 工具，`mode: "bypassPermissions"`），prompt 包含：
- Codex 审查发现的具体 findings 列表
- 修复指令："逐一修复上述 Codex findings"
- 简化指令："主动简化冗余代码——合并重复逻辑、提取共用函数、消除不必要的复杂度"
- 约束："只修改 findings 涉及的文件，不做无关改动"

Fix Agent 完成后进入阶段二。

### 降级逻辑

- **Codex 调用失败**（超时、网络错误、API 错误）→ 记录 WARN `codex-unavailable: {error}`，跳过审查直接进入阶段二
- **401 Unauthorized** → 上述降级处理 + 额外提示用户运行 `/codex:setup` 配置 API 凭证

---

## 阶段二：提交

检查未提交的改动：

```bash
git status
git diff --cached
```

如有未提交内容，按项目规范创建 commit：
- 格式：`type(scope): 描述`（中文描述）
- 不要 `--no-verify`

---

## 阶段三：Rules 维护

维护 `.claude/rules/` 下的子系统摘要文件，确保它们准确反映当前代码状态。

### 跳过条件

如果变更文件全部在 `.claude/`、`data/`、`e2e/`、`scripts/`、`*.md` 范围内（不涉及运行时代码），跳过此阶段。

### 轻量验证

1. 运行 `git diff main...HEAD --name-only` 获取变更文件列表
2. 读取 `.claude/rules/` 下所有 rule 文件
3. 将变更文件与每个 rule 的 `paths` frontmatter 做 glob 匹配
4. **已匹配的 rule**：对比 diff 语义与 rule 描述，回答："这个 rule 还准确吗？"
5. **未匹配的变更文件**：检查是否有源文件不属于任何 rule 的 paths 覆盖范围。如果这些文件构成一个**独立子系统**（有自己的设计决策、架构约束、多文件协作），应新建 rule

**需要新建 rule 的信号**：
- 变更引入了全新的目录或模块，且有 3+ 个源文件
- 该模块有自己的设计决策体系（认证方式、协议约定、错误处理策略等），不是某个已有子系统的简单延伸
- 后续开发者修改相关代码时，需要了解这些决策才能做出正确选择

**不需要新建 rule 的信号**：
- 变更文件是已有子系统的自然扩展
- 模块逻辑简单，阅读源码即可理解，无隐含的架构约束
- 单个工具文件或配置文件，不构成独立子系统

**需要更新已有 rule 的信号**：
- 新增了 rule 未提及的重要机制（新模块、新设计模式）
- rule 描述的行为已被重写或删除
- 「已有资产」清单有增减
- 「当前状态」描述与实际不符

**不需要更新的信号**（大多数 finish 命中这里）：
- bug 修复、性能优化等不改变架构描述的变更
- 已有功能的参数调整、阈值变更
- rule 已用概括性描述涵盖的变更

### 执行更新

**全部准确** → 跳过，继续阶段四。

**有 rule 需要更新** → spawn `finish-rules-writer` subagent，附带更新清单：
```
需要更新：
- {filename}：{diff 引入了什么变化，rule 中哪里不一致}
需要新建：（如有新的顶层子系统）
- {建议的 filename}：{覆盖哪个新模块/子系统}
```

等待 subagent 完成后，将 rule 变更单独提交：
- 格式：`chore(rules): 同步 {subsystem} 子系统摘要`

**兜底**：如果 subagent 失败（异常退出或超时），跳过 rules 更新，在结案报告中标记 Rules 更新失败，建议手动检查，继续阶段四。

---

## 阶段四：合并

```bash
bash $PROJECT_DIR/scripts/finish.sh
```

**冲突处理：** 如果 rebase 冲突退出：
1. 读取冲突文件，理解双方改动意图
2. 编辑解决冲突（保留两边有效内容，删除标记）
3. `git add <resolved_files> && git rebase --continue`
4. 重新运行 `bash $PROJECT_DIR/scripts/finish.sh`

**部署策略：默认不部署。** finish 只合并到 main，部署由用户集中安排。仅当用户明确要求立即部署时，才执行 `bash $PROJECT_DIR/scripts/deploy.sh`。

---

## 阶段五：Plan 进度回写

### 扫描与匹配

```bash
node $PROJECT_DIR/scripts/scan-todo.js
```

基于脚本输出的结构化摘要，将变更文件、commit message、涉及的子系统与 plan/子任务做语义匹配。

**无关联 plan** → 跳过。

### 更新关联 plan

只读取匹配到的 plan 原文件（`$PROJECT_DIR/data/todo/{name}.md`），执行以下更新：

1. 完成的子任务状态改为 `✅ 已完成`，补充产出和传递信息：
   ```
   ### T{N}: 任务描述 ✅ 已完成
   - **产出**：{commit hash}；{改了哪些文件/模块}
   - **传递信息**：{执行中的意外、决策变更、踩坑记录}
   ```
2. 更新 plan 顶部的 `**进度**` 行（如 `3/5` → `4/5`）
3. 如有新产生的后续任务 → 追加 `### T{N}: {名称} ⬚ 待开始`
4. 如有新的关键决策 → 追加到「关键决策」区域
5. 在底部「更新记录」表格追加一行：`| {YYYY-MM-DD} | {简述} |`

**格式约束**（scan-todo.js 解析器依赖，必须严格遵守）：
- 子任务标题：`### T{数字}: {任务名} {emoji} {状态}`
- 进度行：`**进度**：{状态} X/Y`
- 禁止：`### 子任务 1.1:`、四级标题 `####`、中文数字编号

### Plan 清理建议

如果某个 plan 的核心目标已达成，但仍有未完成子任务，评估剩余子任务是否被更好的方案替代、不属于当前项目范围、或优先级低且长期挂起。

如有，向用户建议删除，说明理由。**等用户确认后再删除。**

### 已完成 Plan 归档

如果某个 plan 的**所有子任务**都标记为 `✅ 已完成`，将其移入 done 目录：

```bash
mv $PROJECT_DIR/data/todo/{name}.md $PROJECT_DIR/data/todo/done/{name}.md
```

---

## 阶段六：合并后验证

**Worktree 清洁确认：**
```bash
git status
git diff main...HEAD --stat
```
确认所有改动已合并到 main，worktree 无残留未提交内容。

**部署后验证（仅在阶段四执行了部署时）：**

通过健康检查端点确认服务状态正常。如本次涉及 DB schema 变更，确认迁移已成功执行。

### 6b. 变更范围分析

从 git diff 推导本次变更影响哪些 E2E 测试。

**Step 1: 准备测试环境**

确保测试环境运行最新代码并通过健康检查。具体方式取决于项目配置（如重建 staging、重启 dev server 等）。

**Step 2: 获取变更文件列表**

```bash
git diff main~1...main --name-only
```

**Step 3: 按映射规则确定需要运行的测试**

根据变更文件路径推导需要运行的 E2E 测试。映射规则示例：

| 变更路径模式 | 对应测试 | 验收场景 |
|-------------|---------|---------|
| 认证/权限相关模块 | 认证测试 + 安全测试 | 登录流程验证 |
| API 路由/控制器 | 对应的 API 测试 | 端点功能验证 |
| 前端组件/页面 | 视变更组件而定 | UI 交互验证 |
| 共享模块/工具库 | 视影响范围而定 | 视影响而定 |

> 根据项目实际的目录结构和测试文件组织方式，定制具体的映射表。

如果变更文件全部属于文档、配置、脚本等非运行时代码，跳过 6c-6e，直接进入阶段七。

### 6c. Playwright 自动化测试

根据 6b 映射表确定的测试文件，运行 Playwright 测试子集：

```bash
npx playwright test {mapped_test_files}
```

**Playwright 失败 = 硬阻断**。如果有测试失败：
1. 分析失败原因（读取测试输出和截图）
2. 修复代码问题
3. 重新提交 + 合并（回到阶段二）
4. 重新运行失败的测试，直到全部通过

全部通过后继续 6d。

### 6d. agent-browser 验收

分两类检查：**硬检查**（客观事实，失败 = 硬阻断）和**软检查**（AI 判断，展示证据由用户决定）。

**操作序列参考：**

```
npx agent-browser open http://localhost:$TEST_PORT
npx agent-browser wait --load networkidle
# 执行项目特定的登录流程（如 dev-login API、OAuth mock 等）
npx agent-browser snapshot -i
# 根据 snapshot 中的元素引用 @eN 执行交互
npx agent-browser fill "@input_element" "测试内容"
npx agent-browser click "@submit_button"
npx agent-browser wait --text "预期结果标志" --timeout 60000
npx agent-browser snapshot -i
npx agent-browser screenshot
npx agent-browser close
```

（以上为参考模板，实际元素引用 `@eN` 需从 snapshot 输出中获取。根据项目实际的认证方式和 UI 结构定制操作序列。）

**硬检查——日志事实验证：**

根据 6b 映射表中标注的 agent-browser 验收场景，执行浏览器交互后：

1. 读取测试环境日志，从最新的会话日志中查找工具调用记录
2. 检查是否调用了预期的工具、是否路由到了预期的目录
3. 这些是客观事实——pass/fail 明确。**失败 = 硬阻断**，必须修复后才能继续

**软检查——AI 回复质量评估：**

1. 读取 Agent 的回复文本
2. AI 判断回复是否合理、完整、准确
3. 这是主观判断，有误报风险——展示 Agent 回复 + AI 评分理由 + 截图，**由用户决定是否通过**

### 6e. 验收报告

汇总 6c + 6d 的结果，给出最终判定：

| 判定 | 条件 | 处理 |
|------|------|------|
| **PASS** | 6c 全部通过 + 6d 硬检查全部通过 + 6d 软检查无明显问题 | 继续阶段七 |
| **WARN** | 6c 全部通过 + 6d 硬检查全部通过 + 6d 软检查有疑问 | 展示证据，由用户决定是否继续 |
| **FAIL** | 6c 有失败 或 6d 硬检查有失败 | 硬阻断，修复后重新验证 |

将报告嵌入阶段七的结案报告中（在流水线状态面板的「验证」行后追加「E2E 验收」行）。

---

## 阶段七：结案报告 & 关闭确认

删除断点状态文件：`rm -f $PROJECT_DIR/data/.finish-state`

向用户输出结案报告。报告的核心设计原则：**让用户一眼看到每个环节的运作状态，获得"一切正常"的确定感。**

报告分两部分：上半部分是改动概述，下半部分是流水线状态面板（每个阶段一行，展示该阶段实际发生了什么）。

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Worktree 完工报告
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

本次改动：[X 个文件，+Y/-Z 行]
变更内容：[一句话，非技术用户能理解的语言]

┌─ 流程状态 ────────────────────────────┐
│ 代码审查  [跳过（小改动）/ 简化了 N 处] │
│ 提交      [commit hash + 一句话]      │
│ Rules     [全部准确 / 更新了 X.md]    │
│ 合并      [已合并到 main]             │
│ Plan 回写 [plan-name (X/Y) / 无关联]  │
│ 验证      [worktree 干净 / N worker 在线] │
└───────────────────────────────────────┘

下一步：[T{n} 任务名 / 无待办]
Worktree 干净，所有改动已合并到 main
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
当前 worktree 已完善，可以关闭。
确认后退出 Claude Code 即可。
```

**填写规则**：
- 「变更内容」用非技术语言描述（如"修复了连接断开后不会自动重连的问题"，而非"修复 WebSocket reconnect 逻辑"）
- 流水线每行的状态只有两种：正常完成 / 跳过（附原因）。如果某个阶段出现过问题但已解决，标注并简述（如"合并  冲突已解决，已部署"）
- 「下一步」从 plan 回写结果中提取。如无关联 plan，写"无待办"

等待用户确认是否关闭。

---

## 环境变量

- `TEST_LEVEL=full`：强制全量测试

## AI 判断兜底

- finish.sh 跳过了部署，但变更确实影响运行时 → 手动执行 `bash $PROJECT_DIR/scripts/deploy.sh`
- finish.sh 触发了部署，但仅是注释/重命名 → 无需干预，部署是幂等的

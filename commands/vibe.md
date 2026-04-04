---
name: vibe
description: Vibe Coding Workflow 编排入口——查看状态、启动执行、分析反馈
---

Vibe Coding Workflow 的统一入口。根据 `$ARGUMENTS` 分发到对应子命令。

## 参数解析

读取 `$ARGUMENTS`，按第一个词分发：

| 第一个词 | 子命令 | 示例 |
|----------|--------|------|
| （空） | 工作流概览 | `/vibe` |
| `run` | 启动执行 | `/vibe run interactive-panel-system` |
| `status` | 进度查看 | `/vibe status` |
| `review` | 反馈分析 | `/vibe review interactive-panel-system` |

---

## 子命令：无参数（工作流概览）

当 `$ARGUMENTS` 为空时执行。

**输出内容**（保持简洁，不要长篇大论）：

1. **一句话说明**：三阶段工作流——需求分析（/first-principles）→ Plan 生成（/todo）→ 自动执行（/vibe run）

2. **当前 Plan 状态**：
```bash
node $PROJECT_DIR/scripts/scan-todo.js
```
将脚本输出原样展示给用户。

3. **可用命令列表**：
```
/vibe run <plan>       启动自动化执行
/vibe status           查看 plan 进度
/vibe review <plan>    分析执行报告，提炼改进建议
```

---

## 子命令：run

当 `$ARGUMENTS` 以 `run` 开头时执行。`run` 之后的部分为 plan 名称和可选参数。

**你是调度者，不直接写代码。** 你的职责是派发任务、监控结果、向用户汇报进度。所有开发工作由子 Agent 完成。

### 常量

```
REPO_ROOT=$PROJECT_DIR
PLAN_DIR=$REPO_ROOT/data/todo
LOG_DIR=$REPO_ROOT/data/auto-run-logs
STATE_FILE=$REPO_ROOT/data/.auto-runner-state
PARSER=$REPO_ROOT/scripts/parse-plan-task.js
MAX_FAILURES=2          # 连续失败熔断阈值
```

### Step 0：Worktree 检测与 L1 设置

调度器本身需要运行在一个 worktree 中（称为 L1），子 Agent 的 worktree 称为 L2。

**检测逻辑**：

```bash
CURRENT_BRANCH=$(git -C $REPO_ROOT symbolic-ref --short HEAD 2>/dev/null)
IS_IN_WORKTREE=false
# 如果当前工作目录不是 REPO_ROOT，且当前分支不是 main，则已在 worktree 中
if [[ "$(pwd)" != "$REPO_ROOT" ]] && [[ "$(git symbolic-ref --short HEAD 2>/dev/null)" != "$CURRENT_BRANCH" ]]; then
  IS_IN_WORKTREE=true
fi
```

**分支判断**：

- **当前已在 worktree 中**：
  - `L1_PATH` = 当前工作目录
  - `L1_BRANCH` = 当前分支名
  - 向用户报告：`已检测到 L1 worktree: {L1_PATH} ({L1_BRANCH})`

- **当前在 main 上**：
  - 自动创建 L1 worktree：
  ```bash
  L1_BRANCH="vibe-run-{plan-name}-$(date +%Y%m%d-%H%M%S)"
  L1_PATH="$REPO_ROOT/.claude/worktrees/$L1_BRANCH"
  git -C $REPO_ROOT worktree add "$L1_PATH" -b "$L1_BRANCH" main
  ```
  - 向用户报告：`已创建 L1 worktree: {L1_PATH} ({L1_BRANCH})`

设置 `L1_PATH` 和 `L1_BRANCH` 供后续所有步骤使用。

### Step 1：解析参数并确认 Plan

从 `$ARGUMENTS` 中提取 plan 名称（`run` 之后的第一个词）和可选参数：
- `--max-tasks N`：最多执行 N 个任务
- `--start-from TX`：从指定任务开始
- `--checkpoint`：Phase 切换时暂停确认（**默认开启**）
- `--no-checkpoint`：关闭 Phase 检查点
- `--no-review`：跳过 Review 环节
- `--no-finish`：跳过 /finish（调试用）
- `--phase-merge`：Phase 切换时自动 finish L1 → main（默认关闭。开启后 Evaluator 将失去全局审查能力，仅在明确需要早合并时使用）

确认 plan 文件存在：`$PLAN_DIR/{plan-name}.md`。不存在则列出可用 plan。

### Step 2：展示 Plan 摘要并确认

读取 plan 文件，展示：Plan 名称、目标、总任务数/已完成数/下一个待执行任务。

所有任务已完成则提示并结束。否则向用户确认执行参数后开始。

### Step 2.5：清理旧产物 + 生成 Eval Contract

**清理**：删除 `$LOG_DIR` 中当前 plan 的旧任务结果文件，避免 Evaluator 和调度器读到过期数据：

```bash
rm -f $LOG_DIR/{plan-name}-eval-contract.md $LOG_DIR/{plan-name}-eval-report.md
# 仅清理 plan 中存在的任务 ID 对应的 result 文件（不误删其他 plan 的）
for id in $(node $PARSER $PLAN_DIR/{plan-name}.md --list-ids 2>/dev/null); do
  rm -f $LOG_DIR/{plan-name}-${id}-result.md $LOG_DIR/{plan-name}-${id}-error.md
done
```

**生成 Eval Contract**：从 plan 中提取所有任务的退出标准和验证命令，生成独立的 Eval Contract 文件。这是 Evaluator Agent 的**唯一输入**——与 plan 的实现细节隔离。

```bash
node $PARSER $PLAN_DIR/{plan-name}.md --eval-contract > $LOG_DIR/{plan-name}-eval-contract.md
```

记录 `EVAL_CONTRACT=$LOG_DIR/{plan-name}-eval-contract.md`。

### Step 3：任务执行循环

初始化追踪状态：`completed=0, failed=0, consecutive_failures=0, last_id="", current_phase="", results=[]`

写入状态文件：`echo "started:$(date -Iseconds):plan={plan}" > $STATE_FILE`

**每轮迭代：**

#### 3a. 获取下一个任务

```bash
node $PARSER $PLAN_DIR/{plan-name}.md --json [--start-from X | --skip-past {last_id}]
```

退出码 != 0 → 所有任务完成，跳到 Step 3.5（Evaluator）。

从 JSON 输出提取 `id, title, content, verifyCommands, phase`。

#### 3b. Phase 检查点

如果启用 checkpoint，且 `phase` 与 `current_phase` 不同（非首个任务）：
- 向用户报告上一个 Phase 的统计（通过/失败/cost）
- 等待用户确认继续

**注意**：`current_phase` 在 3b+ 完成后才更新（见下方）。

#### 3b+. Phase 切换处理

**默认行为（推荐）**：不合并到 main。所有任务产出累积在 L1，由 Evaluator 统一审查后再合并。Phase 切换时只更新 `current_phase = phase`，并 rebase L1 到最新 main 以避免分支过度漂移：

```bash
cd $L1_PATH && git fetch origin && git rebase origin/main
```

rebase 失败 → 向用户报告冲突，暂停等待确认。

**`--phase-merge` 模式**：仅当显式设置 `--phase-merge` 时，在 Phase 切换点执行 L1 → main 合并：

1. **L1 → main 合并**：
```bash
cd $L1_PATH && bash $PROJECT_DIR/scripts/finish.sh
```

finish.sh 失败 → 向用户报告错误，暂停等待确认。

2. **L1 重新对齐**：
```bash
cd $L1_PATH && git fetch origin && git rebase origin/main
```

⚠️ **注意**：`--phase-merge` 会导致代码在 Evaluator 审查前到达 main。选择此模式意味着放弃 Evaluator 的全局门禁作用。仅在 plan 规模极大（>20 个任务）、需要中间检查点的场景下使用。

更新 `current_phase = phase`。

#### 3c. 报告任务开始

向用户报告：

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[{n}] {id} — {title}
验证命令: {count} 条 | Phase: {phase}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

记录 `l1_head_before`：`git -C $L1_PATH rev-parse HEAD`

更新状态文件：`echo "running:$(date -Iseconds):task={id}" > $STATE_FILE`

#### 3d-pre. 反合理化约束

<RATIONALIZATION-PREVENTION>
你是调度器。在构建子 Agent prompt 时，以下行为被严格禁止：

| 你会想的 | 为什么不能这么做 |
|----------|------------------|
| "这个任务在 CLI 环境做不了全部，做一部分总比不做好" | 做一部分然后报 DONE 比不做更糟——它让所有人以为做完了。子 Agent 有完整工具链，能做到的比你预想的多 |
| "验证命令可能跑不通，我换个等效验证方式" | verifyCommands 是 plan 定义的验收标准，不得替换、简化或省略 |
| "这个任务有外部依赖，先标 BLOCKED 省得浪费一轮" | 子 Agent 有能力自主判断是否 BLOCKED。调度器的职责是如实派发，不是预判失败 |
| "端到端测试在 CLI 环境跑不了，我在 prompt 里提示子 Agent 这一点" | 你不知道子 Agent 的能力边界。Plan 的验证步骤已定义了期望，如果期望不合理那是 plan 的问题，不是你该在派发时修正的。添加任何暗示"这个可能做不到"的措辞，等于在结果出来前就给了子 Agent 放弃的许可 |

**硬性规则**：任务的 `content` 和 `verifyCommands` 必须原样插入子 Agent prompt，不得修改、摘要、省略、重排。**prompt 的其他部分（包括上下文说明、工作目录描述等）也不得包含任何暗示任务可能无法完成、建议降低标准、或预设失败预期的措辞。** 调度器的全部判断权限仅限于：任务排序、worktree 分配、前置依赖检查。任务可行性判断属于子 Agent 的职权。
</RATIONALIZATION-PREVENTION>

#### 3d. 派发子 Agent

使用 **Agent 工具** 派发：

| 参数 | 值 |
|------|----|
| `isolation` | `"worktree"` |
| `mode` | `"bypassPermissions"` |
| `description` | `"{id}: {title}"` |

**子 Agent Prompt**（动态构建）：

```
你正在执行 {plan-name} plan 的任务 {id}。这是自动化流水线，无需等待用户确认。

## 第一步：了解上下文
1. 读取 CLAUDE.md——理解本项目的架构概览和关键约束
2. 读取完整 plan 文件：{PLAN_DIR}/{plan-name}.md
3. 理解整体架构和当前任务的位置
4. 检查前置任务的产出（如有）——已完成任务的「产出」和「传递信息」字段包含关键上下文
5. 特别关注 plan 的「不在范围内」区块，那些事不要做
6. 关注「已有资产」区块，优先复用已有代码

## 第二步：执行任务
当前任务：**{id} — {title}**

{content}

逐一完成所有 checklist 项。完成后执行任务中的**验证**步骤。
验证必须全部通过。失败则修复后重新验证。

{如果有 verifyCommands，插入：
## 验证门槛
以下命令必须全部成功（exit code 0）：
- `{cmd1}`
- `{cmd2}`
如果任何命令失败，先修复代码再重新验证。}

## 第三步：提交代码
所有验证通过后，将改动提交到当前 worktree 分支：
1. `git add` 相关文件（不要 git add -A）
2. `git commit` 写清楚改动内容
**不要执行 /finish，不要合并到 main。** 提交到 worktree 分支后你的任务就完成了。

## 第四步：写入结果文件
提交代码后，将任务结果写入 `{LOG_DIR}/{plan-name}-{id}-result.md`，格式如下：

```markdown
# Task Result: {id}

## STATUS: DONE | DONE_WITH_CONCERNS

## 产出
- {改动的文件和行数变化}
- {额外修复或发现}

## 验证结果
- `{verify_cmd_1}` → 通过/失败 + 关键输出
- `{verify_cmd_2}` → 通过/失败 + 关键输出


## 已知问题
{DONE_WITH_CONCERNS 时列出 concerns，否则写"无"}
```

这个文件会被调度器和独立的 Evaluator Agent 分别读取——写完整、写准确。

## 测试纪律
新增或修改了行为的代码，必须有对应的测试。如果任务的 Spec 没有指定测试文件路径，在相邻的 `__tests__/` 目录创建测试文件，遵循项目现有命名约定（`*.test.ts` / `*.integration.test.ts`）。验证命令中必须包含运行这些新测试的命令。
豁免：纯配置变更（如只改 .env 或 config 常量）不需要写测试。

## 约束
- 无人值守执行，不要提问或等待输入
- 需要决策时根据 plan 设计说明自主判断
- **没有 BLOCKED 状态**——如果验证命令不通过，继续排查和修复直到通过或用尽所有手段。只有验证命令全部 exit code 0 才能报 DONE
- 代码质量：编译通过、测试通过、符合项目风格
```

#### 3e. 处理子 Agent 返回

计算耗时。从 Agent 工具的返回结果中提取 **worktree 路径和分支名**（Agent 工具在 `isolation: "worktree"` 模式下，如果有代码变更，会在结果中返回 worktree 路径和分支）。

**读取结果文件**：检查 `$LOG_DIR/{plan-name}-{id}-result.md` 是否存在。如果存在，读取其内容作为结构化结果（供后续 Evaluator 消费）。如果不存在，回退到从 Agent 返回文本解析。

**解析完成状态**：优先从结果文件的 `## STATUS:` 行提取，其次从子 Agent 返回内容中提取 `STATUS:` 行：

- **DONE** → 正常继续到 3f（验证命令门槛）
- **DONE_WITH_CONCERNS** → 标记 WARN `has-concerns`，提取 concerns 列表记录到 results，正常继续到 3f

**子 Agent 不会报 BLOCKED**——它只有 DONE 和 DONE_WITH_CONCERNS 两种状态。如果子 Agent 未能让验证命令通过，调度器在 3f 会发现。

**其他失败判断**（与状态协议并行检查）：
- **子 Agent 异常退出**：记录 FAIL，`consecutive_failures++`，跳到 3h
- **无 worktree 返回**（Agent 无变更，worktree 被自动清理）→ 交叉判断 STATUS：

  | STATUS | 处理 |
  |--------|------|
  | DONE / DONE_WITH_CONCERNS | **无代码任务**——标记 `no_git_diff = true`，正常继续到 3f（验证命令在 `$L1_PATH` 中运行）。跳过 3g++（无分支可 merge），但**仍执行 3g（审查）和 plan 回写** |
  | 未找到 STATUS 行 | 真正的 empty-diff 异常——标记 WARN `empty-diff`，跳到 3h |

有 worktree 返回时，记录 `worktree_path` 和 `worktree_branch`（这是 L2 的路径和分支），后续步骤均在此 L2 worktree 上操作。

#### 3f. 验证命令门槛

仅当 `verifyCommands` 非空时执行。运行目录取决于是否有 L2 worktree：

```bash
# 有 L2 worktree（正常情况）
cd {worktree_path} && {verify_cmd}

# no_git_diff = true（无代码任务，无 L2）
cd $L1_PATH && {verify_cmd}
```

<RATIONALIZATION-PREVENTION>
验证命令是**硬门控**。以下理由均不得用于跳过任何验证命令：

| 你会想的 | 为什么不能这么做 |
|----------|------------------|
| "子 Agent 已经验证过了" | 子 Agent 的验证环境是 L2 worktree，调度器需要在合并目标环境中独立验证 |
| "需要外部服务不可用" | 验证命令由 plan 作者定义，如果它依赖外部服务，那就是退出标准的一部分。不可用 = 不通过 |
| "这是无代码任务，验证没意义" | 无代码不影响验证命令的执行义务 |
| "验证命令标了 [WEAK]，语义上已经通过了" | [WEAK] 是给 Evaluator 的提示，不是给调度器跳过的许可 |

**无条件逐条执行所有 verifyCommands。exit code 0 = 通过，非 0 = 不通过。调度器不做二次判断。**
</RATIONALIZATION-PREVENTION>

全部通过 → 标记 `verify_passed_at = git rev-parse HEAD`（记录验证时的 commit），进入 3g。

**任何命令失败 → 先做失败归属分流，再决定是否修复：**

##### 失败归属分流

对每个失败的验证命令，判断失败是否由当前任务引入：

1. **获取任务变更文件**：`git -C {worktree_path} diff main..HEAD --name-only`
2. **分析失败输出**：错误是否指向任务变更的文件？错误信息是否与任务改动相关？
3. **分类**：
   - **In-task failure**（任务引入的）：错误指向任务改动的文件，或能追溯到本次变更 → 派发 Fix Agent 修复
   - **Pre-existing failure**（合并前已有的）：错误指向未被任务修改的文件，且与本次变更无关 → 标记 WARN `pre-existing-failure`，记录失败详情，**跳过修复，继续进入 3g**
   - **存疑时默认归为 in-task**——宁可多修一次，不能放过真实问题

##### Fix Agent 修复（仅 in-task failure）

派发 **Fix Agent**（Agent 工具，**不用 isolation**，`mode: "bypassPermissions"`）。Fix Agent 在**已有的 L2 worktree** 上修复，不创建新 worktree：

```
你正在修复 {plan-name} plan 的任务 {id} 的验证失败。

## 工作目录
你的所有文件操作必须在 {worktree_path} 下进行（Read/Edit/Write 用绝对路径）。
运行命令时先 cd 到该目录。

## 失败的验证命令
`{failed_cmd}`

## 失败输出
{output, 截取末尾 100 行}

## 原始任务描述
{content}

## 你的任务
1. 读取 plan 文件了解上下文
2. 分析验证失败的原因
3. 修复代码使验证命令通过
4. 重新运行失败的验证命令，确认修复有效
5. git add + git commit 提交修复（不要执行 /finish）

约束：无人值守，只修复验证问题，不改无关代码。修复后必须重跑验证确认通过再提交。
```

Fix Agent 返回后在 L2 worktree 中**重新运行所有验证命令（不只是失败的那条）**。仍失败 → 记录 FAIL，跳到 3h。通过 → 更新 `verify_passed_at`。

#### 3g. Code Quality 快扫（Codex 对抗审查）

逐任务的轻量审查——只检查代码结构质量，不检查 Spec 符合性（由验证命令覆盖）。目的是在合并前拦截结构性缺陷（安全漏洞、资源泄漏等）。审查由 Codex（GPT-5.4）执行，提供与编写者不同模型的对抗视角。

跳过条件：`--no-review`、空 diff。

**Diff 来源**：
- **正常任务**（有 L2 worktree）：`git -C {worktree_path} diff main..HEAD`

**执行 Codex 对抗审查**：

**调度器必须先 `cd {worktree_path}` 确保当前工作目录为 L2 worktree**，然后调用 `/codex:adversarial-review --scope working-tree --effort medium --wait`。Codex 通过 `process.cwd()` 继承工作目录。
Codex adversarial-review 是 read-only 的，输出为自由文本 stdout。

**降级逻辑**：

Codex 调用可能失败（超时、API 错误、服务不可用）。降级处理：
- **一般错误**（超时、网络、API 错误）：记录 WARN `codex-unavailable`，跳过审查直接进入 3g+
- **401 Unauthorized**：记录 WARN `codex-unavailable`，额外提示用户运行 `/codex:setup` 检查配置，跳过审查进入 3g+

**VERDICT 映射**（调度器侧）：

Codex 输出是自由文本，不保证携带结构化 severity 标记。由 Claude 调度器读取 Codex stdout，按内容严重程度映射为 VERDICT：

- **PASS**：Codex 未发现实质性问题，或仅有风格/偏好级建议
- **WARN**：Codex 发现了有价值的改进建议但不阻塞——例如缺少边界检查、错误处理可改进、命名不清晰影响可维护性
- **CRITICAL**：Codex 发现了严重的结构性缺陷——安全漏洞（注入、未校验输入、硬编码凭据）、资源泄漏（未关闭连接/句柄）、数据损坏风险、明显的并发安全问题

映射时提取 Codex 输出中的具体 findings，记录为 ITEMS 列表（含文件路径和问题描述）。

解析 VERDICT：
- **PASS** → 进入 3g-fix（跳过）→ 3g+
- **WARN** → 记录 warnings 到 results，进入 3g-fix
- **CRITICAL** → 记录到 results，标记 `has_critical_quality_issues`，进入 3g+（不阻塞，留给 Evaluator 统一处理）

#### 3g-fix. WARN 修复路径

仅当 Quality Scan VERDICT 为 WARN 时执行（PASS 和 CRITICAL 跳过此步）。

派发 **WARN Fix Agent**（Agent 工具，**不用 isolation**，`mode: "bypassPermissions"`）。在已有的 L2 worktree 上操作：

```
你正在修复 {plan-name} plan 的任务 {id} 的代码质量警告。

## 工作目录
你的所有文件操作必须在 {worktree_path} 下进行（Read/Edit/Write 用绝对路径）。
运行命令时先 cd 到该目录。

## Quality Scan 发现的 WARN 项
{quality_scan_items，仅 WARN 级别}

## 原始任务描述
{content}

## 你的任务
1. 读取 plan 文件了解上下文
2. 逐个修复 WARN 项——每个 WARN 应有对应的代码改动
3. 修复后重新运行验证命令确认没有引入回归：
{verifyCommands，逐行列出}
4. git add + git commit 提交修复（不要执行 /finish）

约束：无人值守。只修复列出的 WARN 项，不改无关代码。修复后必须重跑验证确认通过再提交。
```

WARN Fix Agent 返回后：

- **验证命令全部通过** → 更新 `verify_passed_at = git -C {worktree_path} rev-parse HEAD`，清除 WARN 记录，进入 3g+
- **验证命令失败或 Fix Agent 异常** → 降级为记录 WARN（保留原 Quality Scan 的 WARN 记录，不阻塞），进入 3g+

#### 3g+. Verification Gate：合并前重验证

**铁律：代码变更后未经验证不得合并。**

检查当前 L2 HEAD 是否与 `verify_passed_at` 一致：

```bash
cd {worktree_path} && git rev-parse HEAD
```

- HEAD == `verify_passed_at` → 验证结果仍然有效，直接进入 3g++
- HEAD != `verify_passed_at`（Fix Agent 修复产生了新 commit）→ **必须重跑所有验证命令**

<RATIONALIZATION-PREVENTION>
你会想跳过重验证的理由，以及为什么不能跳：

| 你会想的 | 现实 |
|----------|------|
| "Fix Agent 只改了很小的地方" | 小改动破坏生产的案例比大改动多 |
| "之前验证已经通过了" | 之前验证的是不同的 commit，结果已失效 |
| "重跑验证浪费时间" | 合并一个验证失败的 commit 浪费的时间更多 |
</RATIONALIZATION-PREVENTION>

重验证失败 → 记录 FAIL，跳到 3h。重验证通过 → 进入 3g++。

#### 3g++. Finish：L2 → L1 合并

验证有效后，由调度器将子 Agent 的 L2 worktree 合并到 L1（**不是合并到 main**），并回写 plan 文件。

如果 `--no-finish` 被设置，跳过此步骤（调试模式）。

**无代码任务（`no_git_diff = true`）**：跳过步骤 1-2（无 L2 可 merge），直接执行步骤 3（plan 回写）和步骤 4。产出字段写"无代码任务，无 git 变更"。

**正常任务的合并流程**：

```bash
# 1. 将 L2 分支合并到 L1
git -C $L1_PATH merge {worktree_branch} --no-edit
```

合并成功 → 继续步骤 2-4。

**合并冲突处理**：冲突时**必须**派发 **Conflict Fix Agent** 逐文件语义解决。**禁止使用 `git checkout --theirs`/`--ours` 一刀切策略**——同 Phase 内多任务可能修改同一文件的不同部分，机械覆盖会丢失先前任务的改动。调度器自身也不得手动解决冲突（缺乏完整上下文），必须委托给 Agent。

派发参数（Agent 工具，**不用 isolation**，`mode: "bypassPermissions"`）：

```
你正在解决 {plan-name} plan 的任务 {id} 的合并冲突。

## 工作目录
{L1_PATH}（L1 worktree，合并目标分支）

## 冲突来源
L2 分支 {worktree_branch}（任务 {id} 的改动）合并到 L1 时产生冲突。

## 你的任务
1. 运行 `git -C {L1_PATH} diff --name-only --diff-filter=U` 查看冲突文件
2. 逐个读取冲突文件，理解双方改动意图
3. 编辑解决冲突（保留两边有效内容，删除冲突标记）
4. `cd {L1_PATH} && git add <resolved_files> && git commit --no-edit`

约束：无人值守。只解决冲突，不改动非冲突代码。
```

Conflict Fix Agent 返回后验证合并状态。仍有冲突 → 记录 FAIL，跳到 3h。

```bash
# 2. 清理 L2 worktree
git -C $REPO_ROOT worktree remove {worktree_path} --force
git -C $REPO_ROOT branch -d {worktree_branch} 2>/dev/null || true
```

**以下步骤 3-4 对正常任务和无代码任务都执行：**

```bash
# 3. 回写 plan 文件——标记任务完成
```

读取 `$PLAN_DIR/{plan-name}.md`，找到当前任务的标题行（匹配 `### {id}` 或 `#### {id}`），执行以下更新：

- 标题行状态 emoji 改为 `✅ 已完成`（替换 `⬚ 待开始` 或 `🔄 进行中`）
- 在任务内容末尾、下一个任务标题前，追加：
  ```
  - **产出**：`{commit_hash}`；{变更文件数} 个文件 +{insertions}/-{deletions} 行
  - **传递信息**：{从子 Agent 返回内容中提取 concerns 或关键决策；无特殊信息时写"无"}
  ```
  正常任务：`commit_hash` = `git -C $L1_PATH rev-parse --short HEAD`，变更统计 = `git -C $L1_PATH diff HEAD~1 --stat | tail -1`
  无代码任务：产出写"无代码任务，无 git 变更"，传递信息从子 Agent 返回中提取

- 更新 plan 顶部的 `**进度**` 行（X/Y 中 X+1）

```bash
# 4. 记录合并后的 L1 HEAD（无代码任务时 HEAD 不变）
l1_head_after_merge=$(git -C $L1_PATH rev-parse HEAD)
```

计算行数变更：`git -C $L1_PATH diff {l1_head_before}..{l1_head_after_merge} --stat | tail -1`

#### 3h. 记录结果并报告

向用户报告任务结果（一行）：

```
✓ {id} — PASS (5m, +120/-30 行)
⚠ {id} — PASS (5m, +120/-30 行) Quality: WARN — {summary}
✗ {id} — FAIL (8m) 原因: verify-failed
```

将结果追加到 `results` 数组。更新 `completed/failed/consecutive_failures`。

更新状态文件：`echo "{status}:$(date -Iseconds):task={id}:n={completed}" > $STATE_FILE`

**熔断检查**：`consecutive_failures >= MAX_FAILURES` → 报告熔断原因，跳到 Step 3.5（Evaluator）。

否则回到 3a。

### Step 3.5：Evaluator（独立对抗性审查）

全部任务完成后（或熔断后），调用 **Codex Evaluator**（GPT-5.4 对抗审查）对本轮产出做独立终审。

**核心原则**：Evaluator 由不同于代码编写者（Claude）的模型（GPT-5.4）执行，天然不共享 Generator 的推理惯性和系统性盲点。它只看到退出标准和代码差异——模型差异 + 信息不对称是对抗压力的双重来源。

**跳过条件**：`--no-review`、或无 git diff 且无任务结果文件。

**Diff 来源**取决于是否使用了 `--phase-merge`：
- **默认模式**：`git -C $L1_PATH diff main...HEAD`（L1 累积了全部任务产出）
- **`--phase-merge` 模式**：`git -C $REPO_ROOT diff {run_start_main_head}...HEAD`（基于 run 开始前记录的 main HEAD，覆盖已合并到 main 的全部改动）

为支持 `--phase-merge` 模式的 Evaluator，Step 0 中需额外记录 `RUN_START_MAIN_HEAD=$(git -C $REPO_ROOT rev-parse main)`。

#### 3.5a. 准备 Codex Evaluator 的工作上下文

Codex Evaluator 的工作上下文严格限制为以下来源：

1. **Eval Contract**：`$EVAL_CONTRACT`（Step 2.5 生成的退出标准 + 验证命令）
2. **代码差异（git）**：按上述 Diff 来源规则获取（默认模式用 L1 diff，phase-merge 模式用 main diff）
3. **任务结果文件**：`$LOG_DIR/{plan-name}-{id}-result.md`（每个任务的结构化产出）

**不提供给 Codex Evaluator 的**：plan 文件全文（含实现讨论和决策理由）、子 Agent 的推理过程、Quality Scan 记录。

#### 3.5b. 调用 Codex Evaluator

**调度器必须先 `cd {L1_PATH}` 确保当前工作目录为 L1 worktree**，然后执行 `/codex:rescue --effort high --wait`，将以下 prompt 作为任务文本传入。Codex 进程通过 `process.cwd()` 继承工作目录——不显式 cd 到 L1 会导致 Codex 在错误目录执行验证命令：

```
你是独立的质量审计员。你不知道这段代码是怎么写出来的，你只知道它应该满足什么标准。

## 工作目录
{L1_PATH}（在此目录中执行所有验证命令）

## 你的唯一输入
1. Eval Contract（退出标准 + 验证命令）：读取 {EVAL_CONTRACT}
2. 代码差异（git）：`git -C {L1_PATH} diff main...HEAD`
3. 任务结果文件：读取 {LOG_DIR}/{plan-name}-*-result.md

## 审查流程

### Pass 1：退出标准逐条验证
读取 Eval Contract 的每一条退出标准，逐条验证：
- 用验证命令实际执行（在 {L1_PATH} 中 cd 后运行），不是推理"应该能过"
- 对每条退出标准，在 diff 中找到对应实现（引用文件:行号）
- `[WEAK]` 标记的验证命令：命令 PASS **不等于**退出标准 PASS。执行命令后，必须在 diff 中追溯该标准声称的行为是否真正实现（数据流是否正确、边界情况是否处理）
- `[MANUAL]` 标记的退出标准：无自动验证命令，通过代码审查判断
- 没有强度标记的退出标准，通过代码审查判断
- 结果：[PASS] / [FAIL] + 具体证据（命令输出 / 代码位置 / 截图）

### Pass 2：Code Quality（对抗性审查）
综合全部 diff，像攻击者一样思考：
- 安全隐患：注入、未校验输入、硬编码凭据
- 未处理的错误路径、资源泄漏
- 类型不安全、性能问题
- 硬编码的魔法数字/字符串
不要找代码风格问题——只找会在生产中爆炸的问题。

### Pass 3：Cross-task Consistency（≥2 个结果文件时执行）
检查跨任务产出的一致性：
- 接口匹配：A 任务导出的函数签名，B 任务调用时是否一致？
- 命名一致：同一概念在不同任务中是否用了不同名称？
- 重复代码：不同任务是否各自实现了相似逻辑？

<structured_output_contract>
严格按以下格式输出结果：

EXIT_CRITERIA:
- [PASS|FAIL] {任务 ID}: {退出标准} — {证据}

CODE_QUALITY:
- [PASS|WARN|FAIL] {具体项}

CROSS_TASK: (仅多任务时)
- [OK|ISSUE] {具体项}

VERDICT: PASS | WARN | FAIL
SUMMARY: {一句话总结}

VERDICT 规则：
- 任何 EXIT_CRITERIA FAIL → FAIL
- 任何 CODE_QUALITY FAIL → FAIL
- 只有 WARN/ISSUE → WARN
- 全部 PASS + 全部 OK → PASS
</structured_output_contract>

## 纪律
- 禁止赞美。禁止"总体来说不错"。只报告事实。
- 对每个 PASS 判定，必须附上验证证据（命令输出或代码位置）。没有证据的 PASS 等于没验证。
- 如果你发现自己想说"应该没问题"或"看起来正确"——停下来，去实际运行验证命令。
```

**降级逻辑**：如果 `/codex:rescue` 调用失败（超时、API 错误、进程异常），回退到 Claude Evaluator Agent 执行完整的三遍扫（终审不能跳过）。如果错误为 401 Unauthorized，额外提示用户运行 `/codex:setup`。

<details>
<summary>降级 fallback：Claude Evaluator Agent（Codex 不可用时使用）</summary>

派发 **Evaluator Agent**（Agent 工具，不需要 worktree，`mode: "bypassPermissions"`），使用与上述 Codex prompt 相同的审查流程和输出格式：

```
你是独立的质量审计员。你不知道这段代码是怎么写出来的，你只知道它应该满足什么标准。

## 你的唯一输入
1. Eval Contract（退出标准 + 验证命令）：读取 {EVAL_CONTRACT}
2. 代码差异（git）：`git -C {L1_PATH} diff main...HEAD`
3. 任务结果文件：读取 {LOG_DIR}/{plan-name}-*-result.md

## 审查流程

### Pass 1：退出标准逐条验证
读取 Eval Contract 的每一条退出标准，逐条验证：
- 用验证命令实际执行（在 {L1_PATH} 中 cd 后运行），不是推理"应该能过"
- 对每条退出标准，在 diff 中找到对应实现（引用文件:行号）
- `[WEAK]` 标记的验证命令：命令 PASS **不等于**退出标准 PASS。执行命令后，必须在 diff 中追溯该标准声称的行为是否真正实现（数据流是否正确、边界情况是否处理）
- `[MANUAL]` 标记的退出标准：无自动验证命令，通过代码审查判断
- 没有强度标记的退出标准，通过代码审查判断
- 结果：[PASS] / [FAIL] + 具体证据（命令输出 / 代码位置 / 截图）

### Pass 2：Code Quality（对抗性审查）
综合全部 diff，像攻击者一样思考：
- 安全隐患：注入、未校验输入、硬编码凭据
- 未处理的错误路径、资源泄漏
- 类型不安全、性能问题
- 硬编码的魔法数字/字符串
不要找代码风格问题——只找会在生产中爆炸的问题。

### Pass 3：Cross-task Consistency（≥2 个结果文件时执行）
检查跨任务产出的一致性：
- 接口匹配：A 任务导出的函数签名，B 任务调用时是否一致？
- 命名一致：同一概念在不同任务中是否用了不同名称？
- 重复代码：不同任务是否各自实现了相似逻辑？

## 输出格式（严格遵循）

EXIT_CRITERIA:
- [PASS|FAIL] {任务 ID}: {退出标准} — {证据}

CODE_QUALITY:
- [PASS|WARN|FAIL] {具体项}

CROSS_TASK: (仅多任务时)
- [OK|ISSUE] {具体项}

VERDICT: PASS | WARN | FAIL
SUMMARY: {一句话总结}

VERDICT 规则：
- 任何 EXIT_CRITERIA FAIL → FAIL
- 任何 CODE_QUALITY FAIL → FAIL
- 只有 WARN/ISSUE → WARN
- 全部 PASS + 全部 OK → PASS

## 纪律
- 禁止赞美。禁止"总体来说不错"。只报告事实。
- 对每个 PASS 判定，必须附上验证证据（命令输出或代码位置）。没有证据的 PASS 等于没验证。
- 如果你发现自己想说"应该没问题"或"看起来正确"——停下来，去实际运行验证命令。
```

</details>

#### 3.5c. 处理 Evaluator 结果

将 Codex Evaluator（或降级 Claude Evaluator）的完整输出写入 `$LOG_DIR/{plan-name}-eval-report.md`。

**VERDICT 解析**（Claude 调度器执行）：

1. **结构化解析**：在输出中查找 `VERDICT: PASS|WARN|FAIL` 格式行，提取 VERDICT
2. **自由文本回退**：如果 Codex 输出不严格遵循上述格式（缺少 VERDICT 行、格式偏差等），Claude 调度器从完整输出的自由文本中推断 VERDICT：
   - 存在未满足的退出标准 / 严重代码缺陷 → **FAIL**
   - 仅存在建议性问题 / 非阻塞警告 → **WARN**
   - 全部验证通过且无实质性问题 → **PASS**
3. 如果连自由文本也无法判定（输出为空或完全无关），视为 Codex 调用失败，触发降级逻辑

根据 VERDICT：

- **PASS** → 记录 `eval_result = PASS`，进入 Step 4
- **WARN** → 派发 Eval Fix Agent（与 FAIL 相同路径），最多 1 轮修复。修 WARN 成本低，不留技术债
- **FAIL** → 派发 Eval Fix Agent（见下方），最多 1 轮修复

##### Eval Fix Agent

派发 **Eval Fix Agent**（Agent 工具，不需要 worktree，`mode: "bypassPermissions"`）：

```
你正在修复 Evaluator 发现的问题。

## 工作目录
{L1_PATH}（L1 worktree）

## Evaluator 的完整报告
读取 {LOG_DIR}/{plan-name}-eval-report.md

## Eval Contract
读取 {EVAL_CONTRACT}

## 你的任务
1. 读取 Evaluator 报告，识别所有 FAIL 项
2. 逐个修复——优先修 EXIT_CRITERIA FAIL（标准未满足），然后修 CODE_QUALITY FAIL，最后修 CROSS_TASK ISSUE
3. 不要改动 Evaluator 未提及的代码
4. 修复后在 {L1_PATH} 中运行 Eval Contract 中的所有验证命令，确认修复有效
5. git add + git commit 提交修复

约束：无人值守。只修复 Evaluator 指出的问题。
```

Fix Agent 返回后重跑全量验证（Eval Contract 中所有验证命令在 `$L1_PATH` 中执行）。
- 全部通过 → 记录 `eval_result = FIXED`，进入 Step 4
- 任何失败 → 记录 `eval_result = FIX_FAILED`，进入 Step 4（不再重试，留给用户处理）

### Step 4：执行摘要

生成摘要报告写入 `$LOG_DIR/{plan-name}-{timestamp}-summary.md`，包含：
- 统计表：通过/失败/Quality WARN/总行数/总耗时
- 任务汇总表（按 Phase 分组）：ID、标题、耗时、行数、Quality Scan、状态
- Evaluator：VERDICT + SUMMARY + 各 Pass 结果（Exit Criteria / Code Quality / Cross-task）
- 如果有 Eval Fix：修复是否成功、修复了哪些项
- 异常信号：耗时>20m、文件>10个、空 diff、Quality CRITICAL
- L1 分支状态：`{L1_PATH}`（`{L1_BRANCH}`），`git -C $L1_PATH diff main...HEAD --stat | tail -1`

{如果 plan 包含 `## 手动验证` 区块，在摘要末尾追加：}
### 手动验证清单
{手动验证区块内容，原样输出}

清理状态文件（全部成功时删除）。

向用户展示统计摘要，提示 `/vibe review {plan-name}` 可分析改进建议。

### Step 4.5：全量 /finish（L1 → main）

Evaluator 通过后，将 L1 worktree 的全部产出合并回 main。**这是代码到达 main 的唯一路径**（除非使用了 `--phase-merge`）。

**跳过条件**：`--no-finish` 被设置、或 L1 相对 main 无 diff（`git -C $L1_PATH diff main...HEAD --stat` 为空）。

**执行**：

```bash
cd $L1_PATH && bash $PROJECT_DIR/scripts/finish.sh
```

finish.sh 会执行 rebase + build + test + fast-forward merge 到 main。

- 成功 → 向用户报告合并完成
- 失败 → 向用户报告错误，提示手动处理（`cd {L1_PATH} && bash $PROJECT_DIR/scripts/finish.sh`）

---

## 子命令：status

当 `$ARGUMENTS` 为 `status` 时执行。

### Step 1：Plan 进度

```bash
node $PROJECT_DIR/scripts/scan-todo.js
```

将输出原样展示。

### Step 2：检查运行状态

```bash
cat $PROJECT_DIR/data/.auto-runner-state 2>/dev/null || echo "当前没有正在运行的执行循环"
```

如果存态文件存在，解析并展示：
- 正在执行的 plan 名称
- 当前任务 ID
- 开始时间

### Step 3：最近执行报告

```bash
ls -t $PROJECT_DIR/data/auto-run-logs/*-summary.md 2>/dev/null | head -3
```

如果有报告，列出最近 3 个并提示用户可以用 `/vibe review <plan>` 分析。

---

## 子命令：review

当 `$ARGUMENTS` 以 `review` 开头时执行。

将 `review` 之后的部分作为 plan 名称，按照 `/vibe-review` 的完整流程执行。

具体来说，读取 `.claude/commands/vibe-review.md` 的内容，将 plan 名称作为参数，按其中定义的执行流程操作。

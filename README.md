# TL Workflows

**把 Claude Code 变成自动化开发流水线。**

从需求讨论到代码交付，全链路自动化：需求收敛 → 任务拆解 → 子 Agent 自动执行 → 质量审查 → 合并部署。附带 Session 自优化闭环和安全防护 Hooks。

> 这套工作流在生产环境中持续迭代了 6 个月，经历了数百次 /vibe run 执行循环。不是实验品。

---

## 安装

**Claude Code 插件安装**（推荐）：
```bash
claude plugin add /path/to/tl-workflows
```

**手动安装**（拷贝到项目中）：
```bash
cp -r tl-workflows/commands your-project/.claude/
cp -r tl-workflows/skills your-project/.claude/
cp -r tl-workflows/hooks your-project/.claude/
cp -r tl-workflows/agents your-project/.claude/
cp -r tl-workflows/scripts your-project/scripts/
cp tl-workflows/CLAUDE.md your-project/.claude/
```

安装后在 Claude Code 中输入 `/` 即可看到所有命令。

---

## 30 秒上手

```
你：我想给项目加个搜索功能
AI：（自动触发 /brainstorm）

→ 6 个阶段的需求收敛，产出 Spec 文件
→ /todo 把 Spec 拆成 5 个原子任务
→ /vibe run search-feature 自动执行
→ 5 个子 Agent 在独立 worktree 中并行工作
→ Evaluator 做独立对抗审查
→ /finish 合并到 main，E2E 验证通过
→ 完成
```

你只需要在 `/brainstorm` 阶段回答几个问题，剩下的全自动。

---

## 工作流全景

### 核心管线：Brainstorm → Todo → Vibe → Finish

这是最有价值的工作流链条——从模糊想法到可交付代码的完整闭环。

```
┌─────────────┐     ┌──────────┐     ┌──────────────┐     ┌──────────┐
│ /brainstorm │ ──→ │  /todo   │ ──→ │  /vibe run   │ ──→ │ /finish  │
│ 需求收敛     │     │ 任务拆解  │     │  自动执行     │     │ 完工合并  │
│ → Spec 文件  │     │ → Plan   │     │ → 代码产出    │     │ → main   │
└─────────────┘     └──────────┘     └──────────────┘     └──────────┘
```

#### `/brainstorm` — 需求收敛器

把模糊想法变成完整 Spec。6 个阶段：

1. **Context Gathering** — 理解项目现状
2. **Scope 预判** — 一件事还是多件事？
3. **Questioning** — 一次一个问题，多选优先
4. **Premise Challenge** — 挑战需求前提（这是正确的问题吗？不做会怎样？现有代码能复用吗？）
5. **Alternatives** — 强制生成 2-3 个方案对比
6. **Spec Write** — 写入文件 + 自检 + 可选对抗审查

**核心理念**：每个需求都走这个流程。"简单"需求恰恰是返工的头号来源。

#### `/todo` — 任务拆解

把 Spec 拆解成可自动执行的原子任务。每个任务包含：

- **范围**：精确到行为和文件
- **退出标准**：可判定的 yes/no（不是"实现 XX 功能"）
- **验证命令**：完整可执行的 shell 命令（不是"运行相关测试"）

附带 11 条自动质量自检：粒度、退出标准可判定性、验证命令完整性、跨任务命名一致性、证伪检查……

#### `/vibe run <plan>` — 自动执行管线

**这是核心创新。** 双层 worktree 隔离 + 子 Agent 逐任务执行 + 独立对抗审查。

```
main ─────────────────────────────────────────── main（合并后）
  │                                                ↑
  └── L1 worktree（调度器）──────────────────── /finish
        │       │       │                          ↑
        ├── L2-T1 ──┤   │                      Evaluator
        ├── L2-T2 ──┤   │                    （独立终审）
        └── L2-T3 ──────┘
```

每个任务的执行流程：
1. **派发** — 调度器构建 prompt，spawn 子 Agent 到独立 L2 worktree
2. **执行** — 子 Agent 完成任务，写入结果文件
3. **验证门槛** — 调度器运行所有验证命令（硬门控，不可跳过）
4. **质量审查** — Codex (GPT-5.4) 对抗审查（不同模型消除系统性盲点）
5. **合并** — L2 → L1（含冲突自动解决）
6. **回写** — 更新 Plan 文件进度

全部完成后：
- **Evaluator** 独立终审（退出标准逐条验证 + 代码质量攻击性审查 + 跨任务一致性）
- **Finish** — L1 → main

**防合理化机制**：prompt 中内置 `<RATIONALIZATION-PREVENTION>` 表格，列出调度器"会想跳过的理由"和"为什么不能跳"。

#### `/finish` — 八阶段完工流水线

1. 变更审查（Codex 对抗审查，大改动自动触发）
2. 提交（规范化 commit message）
3. Rules 维护（自动同步子系统摘要文件）
4. 合并到 main
5. Plan 进度回写
6. E2E 自动化验证（Playwright + agent-browser）
7. 结案报告（流水线状态面板）

支持断点恢复——中断后下次自动从断点继续。

---

### Session 优化工具链

分析 Agent 会话表现，持续优化上下文工程。

| 命令 | 功能 |
|------|------|
| `/export-session <id>` | 导出会话为结构化 Markdown 报告 |
| `/optimize-session <id>` | 从第一视角还原 Agent 决策路径，生成优化方案 |
| `/replay-session <id>` | 重放会话验证优化效果（A/B 对比） |
| `/cross-analyze` | 跨多个 Session 识别系统性退化趋势 |
| `/vibe review <plan>` | 从执行报告提炼方法论级改进 |

---

### 自动触发的 Skills

无需手动调用，Agent 根据意图自动激活：

| Skill | 触发场景 | 核心能力 |
|-------|---------|---------|
| **diagnose** | 用户报告 bug、贴报错日志 | 四阶段根因分析：证据收集→假设验证→最小修复→回归验证 |
| **session-optimizer** | 用户说"分析 session"、"复盘会话" | 第一视角还原 Agent 决策路径，识别上下文工程结构性问题 |
| **acceptance** | /finish 后需要验收 | Playwright + agent-browser E2E 验收，最多 2 轮打回 |
| **knowledge-organizer** | 用户说"整理知识"、"归档" | 从暂存区归档知识到正确位置 |

---

### 防护性 Hooks

安装后自动生效，保护你的代码安全。

#### git-guard
拦截所有破坏性 git 操作：force push、hard reset、强制删除分支、clean -f 等。

#### worktree-guard
防止 Agent 写入当前 worktree 之外的文件。

---

### 辅助工具

| 命令/脚本 | 功能 |
|-----------|------|
| `/changelog` | 汇总未发布 commit，生成面向用户的更新公告 |
| `/cleanup-worktrees` | 四道防线安全清理孤立 worktree |
| `/update-sdk` | 更新 Claude Agent SDK（含回滚机制） |
| `scripts/auto-plan-runner.sh` | 无人值守批量执行（支持预算控制、熔断、checkpoint） |

---

## 设计哲学

### 1. 验证命令是硬门控
Plan 中定义的验证命令**无条件执行**。每次代码变更后都必须重新验证。

### 2. 反合理化
所有关键决策点都内置了 `<RATIONALIZATION-PREVENTION>` 机制——预先列出 Agent "会想走捷径的理由"和"为什么不能走"。

### 3. 模型对抗
代码审查由不同于编写者的模型执行（Claude 写代码，GPT-5.4 审查），天然消除同模型的系统性盲点。

### 4. 方法论 > 补丁
`/vibe review` 只沉淀能用 always/never 表述的原则，不沉淀 if-then 补丁。

### 5. Spec 不能跳
即使用户说"直接做吧"，最终产出也必须是一份写入文件的 Spec。

---

## 目录结构

```
tl-workflows/
├── .claude-plugin/plugin.json    # 插件元数据
├── commands/                     # 斜杠命令（/xxx 主动调用）
├── skills/                       # 自动触发的 Skills
├── hooks/                        # 安全防护 Hooks
├── agents/                       # 子 Agent 定义
├── scripts/                      # 辅助脚本
├── CLAUDE.md                     # 插件使用指南
└── README.md
```

---

## 许可

MIT

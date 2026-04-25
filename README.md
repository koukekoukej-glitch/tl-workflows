# TL Workflows

一套 Claude Code 工作流插件，覆盖从需求讨论到代码交付的完整开发周期。

---

## 工作流概览

核心是四个命令组成的开发管线，每个命令的输出是下一个命令的输入：

```
/brainstorm  →  /todo  →  /vibe run  →  /finish
  需求收敛       任务拆解     自动执行      完工合并
  产出 Spec      产出 Plan    产出代码      合并到 main
```

### /brainstorm — 需求收敛

把模糊想法变成结构化的 Spec 文件。六个阶段：理解现状 → 判断范围 → 逐个提问 → 挑战前提 → 方案对比 → 写入 Spec。

所有需求都走这个流程，包括看起来很简单的。Spec 写入文件后才能进入下一步。

### /todo — 任务拆解

读取 Spec，拆解为可自动执行的原子任务。每个任务定义：

- 具体范围（精确到文件和行为）
- 退出标准（可判定的 yes/no）
- 验证命令（完整可执行的 shell 命令）

写完后自动运行 11 条质量自检，覆盖粒度、退出标准可判定性、验证命令完整性、跨任务命名一致性等。

### /vibe run — 自动执行

调度器读取 Plan 文件，逐个派发子 Agent 执行任务。采用双层 worktree 隔离：

```
main
  └── L1 worktree（调度器工作区）
        ├── L2 worktree（任务 1）
        ├── L2 worktree（任务 2）
        └── L2 worktree（任务 3）
```

每个任务经过：子 Agent 执行 → 验证命令门槛 → 代码质量审查 → 合并到 L1。

全部任务完成后，独立的 Evaluator 对 L1 上的全部产出做终审（退出标准逐条验证 + 代码质量审查 + 跨任务一致性检查）。通过后合并到 main。

代码质量审查由不同于编写者的模型执行（Claude 写代码，Codex/GPT 审查），避免同模型的系统性盲点。

### /finish — 完工流水线

七个阶段：变更审查 → 提交 → Rules 维护 → 合并到 main → Plan 进度回写 → E2E 验证 → 结案报告。

支持断点恢复，中断后下次从断点继续。

---

## 常见使用方式

**完整流程**（新功能开发）：
```
/brainstorm        ← 和 AI 讨论需求，产出 Spec
/todo              ← 将 Spec 拆成任务 Plan
/vibe run my-plan  ← 自动执行所有任务
```

**单次改动**（bug 修复、小改动）：
```
直接描述问题       ← diagnose skill 自动触发，走证据→假设→修复→验证流程
/finish            ← 提交、合并、验证
```

**Session 优化**（分析 Agent 表现）：
```
/export-session 42       ← 导出会话报告
/optimize-session 42     ← 第一视角还原 Agent 决策路径，生成优化方案
/replay-session 42       ← 在新上下文下重放，验证优化效果
```

---

## 包含的内容

### 命令

| 命令 | 用途 |
|------|------|
| `/brainstorm` | 需求收敛 → Spec 文件 |
| `/todo` | Spec → 原子任务 Plan |
| `/vibe run <plan>` | 自动执行 Plan |
| `/vibe status` | 查看执行进度 |
| `/vibe review <plan>` | 执行复盘，提炼方法论改进 |
| `/finish` | 完工流水线 |
| `/deploy` | 部署到生产 |
| `/changelog` | 汇总未发布 commit，生成更新公告 |
| `/cleanup-worktrees` | 安全清理孤立 worktree |
| `/update-sdk` | 更新 Claude Agent SDK（含回滚） |
| `/export-session <id>` | 导出会话分析报告 |
| `/optimize-session <id>` | 还原决策路径，生成优化方案 |
| `/replay-session <id>` | 重放会话验证优化效果 |
| `/cross-analyze` | 跨会话模式分析 |

### Skills（自动触发）

| Skill | 触发场景 | 功能 |
|-------|---------|------|
| diagnose | 用户报告 bug、贴报错日志 | 四阶段根因分析：证据收集 → 假设验证 → 最小修复 → 回归验证 |
| session-optimizer | 用户要求分析会话、复盘 | 第一视角还原 Agent 决策路径，定位上下文工程结构性问题 |
| acceptance | /finish 后需要验收 | Playwright + agent-browser E2E 验收，失败后自动生成修复 Plan |

### Hooks

| Hook | 作用 |
|------|------|
| git-guard | 拦截破坏性 git 操作（force push、hard reset、clean -f 等） |
| worktree-guard | 防止 Agent 写入当前 worktree 之外的文件 |

### 脚本

| 脚本 | 用途 |
|------|------|
| `auto-plan-runner.sh` | 无人值守批量执行 Plan（支持预算控制、熔断、checkpoint） |
| `finish.sh` | worktree 分支合并到 main（rebase + 预验证 + fast-forward） |
| `deploy.sh` | 构建、测试、服务重启（支持 zero-downtime reload） |
| `cleanup-worktrees.sh` | 四道防线安全清理 worktree（活跃检测、进程检测、git 安全、年龄阈值） |

---

## 目录结构

```
tl-workflows/
├── .claude-plugin/plugin.json    # 插件元数据
├── commands/                     # 斜杠命令
├── skills/                       # 自动触发的 Skills
├── hooks/                        # 安全防护 Hooks
├── agents/                       # 子 Agent 定义
├── scripts/                      # 辅助脚本
└── README.md
```

## 项目配套脚本

`/vibe run` 管线依赖两个项目级脚本来解析 Plan 文件，需要根据项目自行实现：

| 脚本 | 职责 |
|------|------|
| `scripts/scan-todo.js` | 扫描 `data/todo/` 目录，输出所有 Plan 的进度摘要 |
| `scripts/parse-plan-task.js` | 从 Plan Markdown 中提取下一个待执行任务的结构化数据 |

Plan 文件的格式定义见 `/todo` 命令的「格式约束」部分。

Session 优化工具链（`/export-session`、`/replay-session` 等）同样需要项目实现对应的数据导出和重放脚本。

---

MIT

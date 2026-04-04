# TL Workflows

这是一套经过生产验证的 Claude Code 工作流插件。

## 核心工作流链

```
需求讨论 → /brainstorm → Spec 文件
                ↓
           /todo → Plan 文件（原子任务 + 验证命令）
                ↓
         /vibe run → 自动执行（L1/L2 双层 worktree 隔离，子 Agent 逐任务执行）
                ↓
          /finish → 八阶段完工（审查→提交→Rules→合并→Plan回写→E2E验证→结案）
```

## 快速上手

1. `/brainstorm` — 有想法时先用这个收敛需求
2. `/todo` — 把 Spec 拆解成可自动执行的原子任务
3. `/vibe run <plan-name>` — 自动执行所有任务
4. `/finish` — 提交、合并、验证、结案

## 命令一览

### 开发管线
| 命令 | 用途 |
|------|------|
| `/brainstorm` | 需求收敛 → Spec 文件 |
| `/todo` | Spec → 原子任务 Plan |
| `/vibe run <plan>` | 自动执行 Plan |
| `/vibe status` | 查看执行进度 |
| `/vibe review <plan>` | 执行复盘，提炼方法论 |
| `/finish` | 八阶段完工流水线 |
| `/deploy` | 部署到生产 |

### Session 优化
| 命令 | 用途 |
|------|------|
| `/export-session <id>` | 导出会话分析报告 |
| `/optimize-session <id>` | 还原决策路径，生成优化方案 |
| `/replay-session <id>` | 重放会话验证优化效果 |
| `/cross-analyze` | 跨会话模式分析 |

### 工具
| 命令 | 用途 |
|------|------|
| `/changelog` | 生成更新公告 |
| `/cleanup-worktrees` | 安全清理孤立 worktree |
| `/update-sdk` | 更新 Claude Agent SDK |

## 自动触发的 Skills

以下 Skill 无需手动调用，Agent 会根据用户意图自动激活：

- **diagnose** — 用户报告 bug 时自动触发四阶段根因分析
- **session-optimizer** — 用户要求分析会话时自动触发
- **knowledge-organizer** — 用户要求整理知识时自动触发
- **acceptance** — 在 /finish 后需要验收时自动触发

## 防护性 Hooks

安装后自动生效：
- **git-guard** — 拦截破坏性 git 操作（reset --hard, push --force 等）
- **worktree-guard** — 防止写入当前 worktree 之外的文件

## 目录约定

插件假设以下目录结构（自动创建）：

```
$PROJECT_DIR/
├── data/
│   ├── todo/              # Plan 文件存放处
│   ├── auto-run-logs/     # /vibe run 执行日志
│   ├── session_cases/     # 会话分析报告
│   └── optimization_log/  # 优化记录
└── scripts/               # 辅助脚本
```

## 自定义

- `$PROJECT_DIR` 环境变量指向你的项目根目录
- Plan 文件格式见 `/todo` command 中的模板
- hooks 可在 `hooks/hooks.json` 中启用/禁用

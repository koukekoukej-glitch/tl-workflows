# TL Workflows

Claude Code 开发流程自动化插件。四个命令覆盖从需求讨论到代码交付的完整周期，每个阶段的输出直接喂给下一个阶段。

---

## 流程

```
/brainstorm  →  /todo  →  /vibe run  →  /finish
 需求收敛       任务拆解     自动执行      交付合并
```

### /brainstorm — 需求收敛

把模糊的想法变成结构化的 Spec。六个阶段：理解现状、确定范围、针对性提问、挑战假设、对比方案、输出 Spec。

### /todo — 任务拆解

读取 Spec，拆成原子级可执行任务。每个任务包含：范围（精确到文件和行为）、退出标准（可判定的验收条件）、验证命令（完整 Shell 命令）。自动跑 11 项质量检查。

### /vibe run — 自动执行

调度器在隔离的 git worktree 中派出 sub-Agent 逐个执行任务。流程：执行 → 验证 → 质量审查 → 合并到一级分支。独立评审者终审后合并到主分支。

### /finish — 交付合并

七个阶段：变更审查、提交、Rules 维护、主分支合并、进度更新、端到端验证、最终报告。支持断点恢复。

---

## 其他命令

| 命令 | 功能 |
|------|------|
| `/vibe status` | 查看 Plan 执行进度 |
| `/vibe review` | 手动触发质量审查 |
| `/deploy` | 零停机部署 |
| `/changelog` | 生成变更日志 |
| `/cleanup-worktrees` | 安全清理 worktree（多层验证） |

## 自动触发

| Skill | 触发条件 | 功能 |
|-------|---------|------|
| `diagnose` | 检测到 bug 报告 | 四阶段诊断分析 |
| `session-optimizer` | 会话分析请求 | 会话质量优化 |
| `acceptance` | 端到端验证 | Playwright 自动化验收 |

---

## 安全机制

- **写和审分离** — 写代码和审查代码使用不同的模型实例
- **git 操作守卫** — Hook 拦截 force push、reset --hard 等危险命令
- **worktree 边界保护** — sub-Agent 只能在自己的隔离工作区内操作

---

## 安装

```bash
git clone https://github.com/koukekoukej-glitch/tl-workflows.git
```

Claude Code 插件，遵循 `.claude-plugin/plugin.json` 规范。

---

## License

[MIT](LICENSE)

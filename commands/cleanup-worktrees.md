---
name: cleanup-worktrees
description: 扫描并清理孤立的 git worktree，释放磁盘空间
---

清理累积的孤立 git worktree。交互式流程：先预览，确认后再执行。

## 步骤一：Dry Run

运行清理脚本的预览模式，收集所有 worktree 的状态：

```bash
bash $PROJECT_DIR/scripts/cleanup-worktrees.sh --days 1 --force-clean 2>&1
```

## 步骤二：向用户汇报

把 dry run 的结果整理成**三组**，向用户汇报：

### 1. 可清理（✅）
列出数量和简要分类（agent-* 多少个、opt-* 多少个、命名 worktree 多少个）。不需要逐个列出。

### 2. 活跃会话（🔴）
**逐个列出**名称。这些绝不会被删除，但用户需要知道哪些会话被识别为活跃的。

### 3. 被保护（⛔）
**逐个列出**名称和保护原因（脏改动 / 未合并提交）。告诉用户这些不会被自动清理，如果想处理需要手动操作。

### 4. 太新（⏳）
仅报告数量，不逐个列出。

最后给出一句话总结：本次将清理 N 个 worktree，预计释放约 X GB 空间（按每个 worktree ~130MB 估算）。

## 步骤三：等待用户确认

明确问用户：**确认执行清理吗？**

等用户确认后才继续。不要自动执行。

## 步骤四：执行清理

```bash
bash $PROJECT_DIR/scripts/cleanup-worktrees.sh --execute --force-clean --days 1 2>&1
```

执行后汇报：
- 删除了多少个
- 失败了多少个（如有）
- 剩余多少个 worktree

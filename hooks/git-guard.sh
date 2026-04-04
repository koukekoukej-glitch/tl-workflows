#!/bin/bash
#
# git-guard.sh — PreToolUse hook for Bash tool
#
# 拦截破坏性 git 操作，防止 Claude Code 在未经用户授权时
# 删除分支、移除 worktree、丢弃未提交改动等。
#
# 拦截规则:
#   - git branch -d/-D        删除分支
#   - git worktree remove     移除 worktree
#   - git worktree add --force 覆盖式创建 worktree
#   - git reset --hard        丢弃所有改动
#   - git checkout -- / git restore  丢弃文件改动
#   - git clean -f            删除未跟踪文件
#   - git push --force/-f     强制推送
#   - rm -rf on worktree dirs 直接删除 worktree 目录
#
# Hook 协议:
#   stdin  = JSON { tool_input: { command: "..." } }
#   exit 0 = 放行
#   exit 2 = 拦截（stderr 反馈给 Claude）
#

# 从 stdin 读取 JSON，用 node 提取 command（环境无 jq）
INPUT=$(cat)
COMMAND=$(node -e "
  try {
    const d = JSON.parse(process.argv[1]);
    process.stdout.write(d.tool_input?.command || '');
  } catch(e) {
    process.stdout.write('');
  }
" "$INPUT" 2>/dev/null)

# 如果提取失败，放行（不阻塞正常工作）
[ -z "$COMMAND" ] && exit 0

# ── 危险模式检测 ─────────────────────────────────────

# git branch -d / -D（删除分支）
if echo "$COMMAND" | grep -qE 'git\s+branch\s+.*-[dD]\b'; then
  echo "BLOCKED: git branch -d/-D 会删除分支。请先确认用户明确要求删除。" >&2
  exit 2
fi

# git worktree remove
if echo "$COMMAND" | grep -qE 'git\s+worktree\s+remove\b'; then
  echo "BLOCKED: git worktree remove 会移除 worktree。其中可能有未提交的工作。请先确认用户明确要求。" >&2
  exit 2
fi

# git worktree add --force / -f（覆盖式创建）
if echo "$COMMAND" | grep -qE 'git\s+worktree\s+add\s+.*(-f|--force)\b'; then
  echo "BLOCKED: git worktree add --force 会覆盖目标目录中的文件。请先确认用户明确要求。" >&2
  exit 2
fi

# git reset --hard
if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard\b'; then
  echo "BLOCKED: git reset --hard 会丢弃所有未提交改动。请先确认用户明确要求。" >&2
  exit 2
fi

# git checkout -- . / git checkout .（丢弃改动）
if echo "$COMMAND" | grep -qE 'git\s+checkout\s+(--\s+\.|--)'; then
  echo "BLOCKED: git checkout -- 会丢弃未提交改动。请先确认用户明确要求。" >&2
  exit 2
fi

# git restore . / git restore --worktree（丢弃改动）
if echo "$COMMAND" | grep -qE 'git\s+restore\s+(--worktree|--staged\s+--worktree|\.)'; then
  echo "BLOCKED: git restore 会丢弃未提交改动。请先确认用户明确要求。" >&2
  exit 2
fi

# git clean -f（删除未跟踪文件）
if echo "$COMMAND" | grep -qE 'git\s+clean\s+.*-f'; then
  echo "BLOCKED: git clean -f 会永久删除未跟踪文件。请先确认用户明确要求。" >&2
  exit 2
fi

# git push --force / -f
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*(-f|--force)\b'; then
  echo "BLOCKED: git push --force 会覆盖远程历史。请先确认用户明确要求。" >&2
  exit 2
fi

# rm -rf on worktree directories
if echo "$COMMAND" | grep -qE 'rm\s+.*-r.*worktree'; then
  echo "BLOCKED: 检测到删除 worktree 目录的操作。其中可能有未提交的工作。请先确认用户明确要求。" >&2
  exit 2
fi

# 通过检查，放行
exit 0

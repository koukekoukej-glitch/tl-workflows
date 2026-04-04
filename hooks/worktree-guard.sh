#!/bin/bash
#
# worktree-guard.sh — PreToolUse hook for Edit / Write tools
#
# 当 Claude Code 运行在 worktree 中时，拦截所有试图写入
# worktree 目录之外的 Edit/Write 操作，防止误修改主仓库或其他 worktree。
#
# 检测逻辑:
#   1. 通过 git rev-parse --show-toplevel 获取当前 worktree 根目录
#   2. 如果不在 worktree 中（即在主仓库），直接放行
#   3. 在 worktree 中时，检查目标 file_path 是否以 worktree 根开头
#
# Hook 协议:
#   stdin  = JSON { tool_name: "Edit"|"Write", tool_input: { file_path: "..." } }
#   exit 0 = 放行
#   exit 2 = 拦截（stderr 反馈给 Claude）
#

INPUT=$(cat)

# 提取 file_path
FILE_PATH=$(node -e "
  try {
    const d = JSON.parse(process.argv[1]);
    process.stdout.write(d.tool_input?.file_path || '');
  } catch(e) {
    process.stdout.write('');
  }
" "$INPUT" 2>/dev/null)

# 无路径则放行
[ -z "$FILE_PATH" ] && exit 0

# 获取当前 git 顶层目录（worktree 或主仓库）
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
[ -z "$TOPLEVEL" ] && exit 0

# 检查是否在 worktree 中（commondir 与 gitdir 不同则说明是 worktree）
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null)
GIT_COMMON=$(git rev-parse --git-common-dir 2>/dev/null)

# 标准化为 Unix 路径便于比较
normalize() {
  # 1. 反斜杠→正斜杠  2. MSYS /x/ → x:/  3. 去尾斜杠  4. 小写
  echo "$1" | sed 's|\\|/|g' | sed 's|^/\([a-zA-Z]\)/|\1:/|' | sed 's|/*$||' | tr '[:upper:]' '[:lower:]'
}

NORM_GITDIR=$(normalize "$(cd "$GIT_DIR" 2>/dev/null && pwd)")
NORM_COMMON=$(normalize "$(cd "$GIT_COMMON" 2>/dev/null && pwd)")

# 不在 worktree 中（主仓库），放行
[ "$NORM_GITDIR" = "$NORM_COMMON" ] && exit 0

# ── 在 worktree 中，校验路径 ──

NORM_TOP=$(normalize "$TOPLEVEL")
NORM_FILE=$(normalize "$FILE_PATH")

# 检查目标路径是否在 worktree 内
if [[ "$NORM_FILE" == "$NORM_TOP"/* ]] || [[ "$NORM_FILE" == "$NORM_TOP" ]]; then
  exit 0
fi

# Read project config for additional allowed directories
MAIN_REPO=$(normalize "$(cd "$GIT_COMMON/.." 2>/dev/null && pwd)")
NORM_MAIN_REPO="$MAIN_REPO"

# 主仓库内被 .gitignore 忽略的路径 → 放行（如 data/、server/data/ 等共享目录）
if [[ "$NORM_FILE" == "$NORM_MAIN_REPO"/* ]]; then
  # 构造相对于主仓库的相对路径给 git check-ignore
  REL_PATH="${NORM_FILE#$NORM_MAIN_REPO/}"
  if git -C "$(cd "$GIT_COMMON/.." 2>/dev/null && pwd)" check-ignore -q "$REL_PATH" 2>/dev/null; then
    exit 0
  fi
fi

# Claude Code 内部目录（plans、memory 等）→ 放行
CLAUDE_HOME=$(normalize "${CLAUDE_HOME:-$HOME/.claude}")
if [[ "$NORM_FILE" == "$CLAUDE_HOME"/* ]]; then
  exit 0
fi

# 主仓库 .claude/ 目录 → 放行（hooks、rules 等跨 worktree 共享）
if [[ "$NORM_FILE" == "$NORM_MAIN_REPO/.claude"/* ]]; then
  exit 0
fi

# Path is outside worktree -> block
echo "BLOCKED: Currently working in worktree ($TOPLEVEL), but target path is outside: $FILE_PATH. Please use a path within the worktree." >&2
exit 2

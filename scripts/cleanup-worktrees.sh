#!/usr/bin/env bash
#
# cleanup-worktrees.sh -- Safe cleanup of orphaned git worktrees
#
# Usage:
#   bash cleanup-worktrees.sh              # dry-run (report only)
#   bash cleanup-worktrees.sh --execute    # actually delete
#   bash cleanup-worktrees.sh --days 7     # custom age threshold (default: 3 days)
#   bash cleanup-worktrees.sh --force-clean # allow cleanup of worktrees with harmless dirty files
#
# Safety guarantees (four defense lines):
#   1. Active session detection -- session file written in last 24h -> never delete
#   2. Process detection -- any process references the worktree -> never delete
#   3. Git safety check -- unmerged commits -> never delete; dirty files -> default no delete
#   4. Age threshold -- directory too young -> skip
#   - Default is dry-run; must pass --execute explicitly
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WT_BASE="$MAIN_DIR/.claude/worktrees"

# Claude Code stores session logs under this base path.
# Adjust to match your platform's Claude session directory.
SESSION_BASE="${CLAUDE_SESSION_DIR:-$HOME/.claude/projects}"

MAX_AGE_DAYS=3
SESSION_ACTIVE_HOURS=24   # Session file written within this window -> active
EXECUTE=false
FORCE_CLEAN=false

# Harmless dirty file whitelist -- modifications to these do not represent
# unsaved valuable work. Customize for your project.
HARMLESS_PATTERNS=(
  '.claude/commands/'
  '.claude/settings.json'
  'CLAUDE.md'
)

# -- Argument parsing ---------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute)     EXECUTE=true; shift ;;
    --force-clean) FORCE_CLEAN=true; shift ;;
    --days)        MAX_AGE_DAYS="$2"; shift 2 ;;
    *)             echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# -- Colors -------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
DIM='\033[2m'
NC='\033[0m'

# -- Counters -----------------------------------------------------------
TOTAL=0
SAFE=0
FORCE_SAFE=0
ACTIVE_SESSION=0
ACTIVE_PROCESS=0
BLOCKED=0
YOUNG=0
DELETED=0
FAILED=0

# -- Defense line 1: Active session detection ---------------------------
# Claude Code writes session logs to ~/.claude/projects/{encoded-path}/*.jsonl
# Active sessions keep writing; closed sessions stop.
# We check the most recent .jsonl modification time.

SESSION_THRESHOLD=$((SESSION_ACTIVE_HOURS * 3600))

is_session_active() {
  local name="$1"
  # Claude Code encodes project paths by replacing separators with dashes
  local encoded_name
  encoded_name=$(echo "$MAIN_DIR/.claude/worktrees/$name" | sed 's|[/:\\]|-|g; s|^-||')
  local session_dir="${SESSION_BASE}/${encoded_name}"
  [ ! -d "$session_dir" ] && return 1

  # Find the most recently modified .jsonl file
  local newest_mtime
  newest_mtime=$(find "$session_dir" -name "*.jsonl" -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
  [ -z "$newest_mtime" ] && return 1

  newest_mtime=${newest_mtime%%.*}
  local age=$((NOW - newest_mtime))

  if [ "$age" -lt "$SESSION_THRESHOLD" ]; then
    return 0  # active
  fi
  return 1
}

# -- Defense line 2: Process detection ----------------------------------
# Build a set of worktree names referenced by running processes.
# Platform-specific: uses PowerShell on Windows, ps on Unix.
declare -A PROCESS_ACTIVE

if command -v powershell &>/dev/null; then
  while IFS= read -r wt_name; do
    [ -n "$wt_name" ] && PROCESS_ACTIVE["$wt_name"]=1
  done < <(powershell -Command "Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { \$_.CommandLine -and \$_.CommandLine -match 'worktrees' } | ForEach-Object { if (\$_.CommandLine -match '[\\/]worktrees[\\/]([^\\/\s\"]+)') { \$Matches[1] } }" 2>/dev/null | sort -u)
else
  while IFS= read -r wt_name; do
    [ -n "$wt_name" ] && PROCESS_ACTIVE["$wt_name"]=1
  done < <(ps aux 2>/dev/null | grep -oP '(?<=/worktrees/)[^/\s"]+' | sort -u)
fi

# Check whether all dirty files fall within the harmless whitelist
is_harmless_dirty() {
  local wt_path="$1"
  local dirty_files
  dirty_files=$(git -C "$wt_path" diff --name-only HEAD 2>/dev/null; git -C "$wt_path" diff --cached --name-only 2>/dev/null; git -C "$wt_path" ls-files --others --exclude-standard 2>/dev/null)
  [ -z "$dirty_files" ] && return 1

  while IFS= read -r f; do
    [ -z "$f" ] && continue
    local matched=false
    for pattern in "${HARMLESS_PATTERNS[@]}"; do
      if [[ "$f" == *"$pattern"* ]]; then
        matched=true
        break
      fi
    done
    if ! $matched; then
      return 1
    fi
  done <<< "$dirty_files"
  return 0
}

# -- Remove helper ------------------------------------------------------
do_remove() {
  local wt_path="$1"
  local branch="$2"
  if git worktree remove "$wt_path" --force 2>/dev/null; then
    if [ -n "$branch" ] && [ "$branch" != "main" ]; then
      # Clean up the merged branch
      git branch -d "$branch" 2>/dev/null || true
    fi
    DELETED=$((DELETED + 1))
    return 0
  else
    rm -rf "$wt_path" 2>/dev/null
    if [ ! -d "$wt_path" ]; then
      DELETED=$((DELETED + 1))
      return 0
    fi
    FAILED=$((FAILED + 1))
    return 1
  fi
}

echo ""
echo "=========================================="
echo "  Worktree Cleanup"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Age threshold: ${MAX_AGE_DAYS} days"
echo "  Session active window: ${SESSION_ACTIVE_HOURS} hours"
echo "  Mode: $( $EXECUTE && echo 'EXECUTE' || echo 'DRY RUN' )"
echo "=========================================="
echo ""

# -- Prune stale git internal references --------------------------------
cd "$MAIN_DIR"
PRUNED=$(git worktree prune 2>&1 || true)
[ -n "$PRUNED" ] && echo -e "${DIM}git worktree prune: $PRUNED${NC}"

NOW=$(date +%s)
THRESHOLD=$((MAX_AGE_DAYS * 86400))

# -- Table header -------------------------------------------------------
printf "  %-40s %-8s %-6s %-10s %s\n" "Name" "Age" "Dirty?" "Unmerged?" "Verdict"
printf "  %-40s %-8s %-6s %-10s %s\n" "$(printf '%.0s-' {1..40})" "--------" "------" "----------" "------"

for WT_PATH in "$WT_BASE"/*/; do
  [ ! -d "$WT_PATH" ] && continue
  TOTAL=$((TOTAL + 1))

  NAME=$(basename "$WT_PATH")

  # == Defense line 1: Active session ==
  if is_session_active "$NAME"; then
    printf "  %-40s %-8s %-6s %-10s " "$NAME" "-" "-" "-"
    echo -e "${MAGENTA}ACTIVE SESSION${NC}"
    ACTIVE_SESSION=$((ACTIVE_SESSION + 1))
    continue
  fi

  # == Defense line 2: Process detection ==
  if [ -n "${PROCESS_ACTIVE[$NAME]+x}" ]; then
    printf "  %-40s %-8s %-6s %-10s " "$NAME" "-" "-" "-"
    echo -e "${MAGENTA}PROCESS ACTIVE${NC}"
    ACTIVE_PROCESS=$((ACTIVE_PROCESS + 1))
    continue
  fi

  # -- Check age --
  if [ -f "$WT_PATH/.git" ]; then
    MTIME=$(stat -c %Y "$WT_PATH/.git" 2>/dev/null || echo "$NOW")
  else
    MTIME=$(stat -c %Y "$WT_PATH" 2>/dev/null || echo "$NOW")
  fi
  AGE_SECONDS=$((NOW - MTIME))
  AGE_DAYS=$((AGE_SECONDS / 86400))

  if [ "$AGE_DAYS" -eq 0 ]; then
    AGE_STR="${AGE_SECONDS}s"
  else
    AGE_STR="${AGE_DAYS}d"
  fi

  # -- Check dirty (modified tracked / staged) --
  DIRTY=false
  if ! git -C "$WT_PATH" diff --quiet HEAD 2>/dev/null; then
    DIRTY=true
  fi
  if ! git -C "$WT_PATH" diff --cached --quiet 2>/dev/null; then
    DIRTY=true
  fi

  # -- Check unmerged commits --
  UNMERGED=0
  BRANCH=$(git -C "$WT_PATH" symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ -n "$BRANCH" ] && [ "$BRANCH" != "main" ] && [ "$BRANCH" != "master" ]; then
    UNMERGED=$(git -C "$WT_PATH" log --oneline main..HEAD 2>/dev/null | wc -l | tr -d ' ')
  fi

  # -- Classify --
  DIRTY_STR=$( $DIRTY && echo "yes" || echo "-" )
  UNMERGED_STR=$( [ "$UNMERGED" -gt 0 ] && echo "${UNMERGED}" || echo "-" )

  # == Defense line 3: Git safety check ==
  if [ "$UNMERGED" -gt 0 ]; then
    VERDICT="${RED}BLOCKED: ${UNMERGED} unmerged commits${NC}"
    BLOCKED=$((BLOCKED + 1))
  elif $DIRTY && $FORCE_CLEAN && is_harmless_dirty "$WT_PATH"; then
    if [ "$AGE_SECONDS" -lt "$THRESHOLD" ]; then
      VERDICT="${YELLOW}TOO YOUNG (<${MAX_AGE_DAYS}d)${NC}"
      YOUNG=$((YOUNG + 1))
    else
      VERDICT="${GREEN}SAFE (harmless dirty)${NC}"
      FORCE_SAFE=$((FORCE_SAFE + 1))
      SAFE=$((SAFE + 1))
      $EXECUTE && { do_remove "$WT_PATH" "$BRANCH" && VERDICT="${GREEN}DELETED${NC}" || VERDICT="${RED}DELETE FAILED${NC}"; }
    fi
  elif $DIRTY; then
    VERDICT="${RED}BLOCKED: dirty files${NC}"
    BLOCKED=$((BLOCKED + 1))
  # == Defense line 4: Age threshold ==
  elif [ "$AGE_SECONDS" -lt "$THRESHOLD" ]; then
    VERDICT="${YELLOW}TOO YOUNG (<${MAX_AGE_DAYS}d)${NC}"
    YOUNG=$((YOUNG + 1))
  else
    VERDICT="${GREEN}SAFE${NC}"
    SAFE=$((SAFE + 1))
    $EXECUTE && { do_remove "$WT_PATH" "$BRANCH" && VERDICT="${GREEN}DELETED${NC}" || VERDICT="${RED}DELETE FAILED${NC}"; }
  fi

  printf "  %-40s %-8s %-6s %-10s " "$NAME" "$AGE_STR" "$DIRTY_STR" "$UNMERGED_STR"
  echo -e "$VERDICT"
done

# -- Post-cleanup prune --
if $EXECUTE; then
  git worktree prune 2>/dev/null || true
fi

# -- Summary ------------------------------------------------------------
echo ""
echo "=========================================="
echo "  Summary"
echo "=========================================="
echo "  Scanned:        $TOTAL worktrees"
echo -e "  Active session:  ${MAGENTA}${ACTIVE_SESSION}${NC} (.jsonl written in ${SESSION_ACTIVE_HOURS}h)"
[ "$ACTIVE_PROCESS" -gt 0 ] && echo -e "  Process active:  ${MAGENTA}${ACTIVE_PROCESS}${NC}"
echo "  Safe to clean:   $SAFE (passed all defense lines)"
[ "$FORCE_SAFE" -gt 0 ] && echo "    of which:      $FORCE_SAFE via --force-clean whitelist"
echo "  Too young:       $YOUNG (under ${MAX_AGE_DAYS} days)"
echo "  Protected:       $BLOCKED (dirty files or unmerged commits)"
if $EXECUTE; then
  echo -e "  ${GREEN}Deleted:         $DELETED${NC}"
  [ "$FAILED" -gt 0 ] && echo -e "  ${RED}Failed:          $FAILED${NC}"
else
  echo ""
  echo -e "  ${CYAN}This was a dry run. To execute:${NC}"
  echo "  bash cleanup-worktrees.sh --execute --force-clean"
fi
echo ""

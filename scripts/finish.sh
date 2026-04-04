#!/usr/bin/env bash
#
# finish.sh -- Merge worktree branch to main (merge + verify only, no deploy)
#
# Usage:
#   bash finish.sh          # merge current worktree branch to main
#   bash finish.sh --all    # batch-merge all worktree branches (from main dir)
#   bash finish.sh --sync   # rebase worktree branch onto latest main
#
# Deploy separately on main: bash deploy.sh
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAIN_DIR="$SCRIPT_DIR"
LOCK_FILE="$MAIN_DIR/.merge-lock"
LOCK_TIMEOUT=600  # max lock wait: 10 minutes

# -- Colors -------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()  { echo -e "${RED}[FAIL]${NC} $1"; }

# Silent runner: redirect output to temp file, show summary on success,
# show last 30 lines on failure
run_silent() {
  local label="$1"; shift
  local LOG
  LOG=$(mktemp)

  echo -n "  ${label}..."
  if "$@" > "$LOG" 2>&1; then
    local summary
    summary=$(grep -E "^\s*(Tests|Test Files)" "$LOG" | tail -5)
    if [ -n "$summary" ]; then
      echo ""
      echo "$summary" | sed 's/^/  /'
    else
      echo " done"
    fi
    rm -f "$LOG"
    return 0
  else
    local exit_code
    exit_code=$?
    echo " FAILED!"
    echo "  --- last 30 lines ---"
    tail -30 "$LOG" | sed 's/^/  /'
    echo "  --- full log: $LOG ---"
    return $exit_code
  fi
}

# -- Lock management (mkdir atomic lock) --------------------------------
acquire_lock() {
  local waited=0
  while ! mkdir "$LOCK_FILE" 2>/dev/null; do
    local lock_info="$LOCK_FILE/info"
    if [ -f "$lock_info" ]; then
      LOCK_AGE=$(( $(date +%s) - $(date -r "$lock_info" +%s 2>/dev/null || echo 0) ))
      if [ "$LOCK_AGE" -gt "$LOCK_TIMEOUT" ]; then
        warn "Found stale lock (${LOCK_AGE}s), force-clearing"
        rm -rf "$LOCK_FILE"
        continue
      fi
    fi
    if [ $waited -ge $LOCK_TIMEOUT ]; then
      fail "Merge lock wait timeout (${LOCK_TIMEOUT}s)"
      exit 1
    fi
    if [ $((waited % 10)) -eq 0 ]; then
      LOCK_OWNER=$(cat "$lock_info" 2>/dev/null || echo "unknown")
      info "Another branch is merging ($LOCK_OWNER), waiting... (${waited}s)"
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "$1 (PID $$)" > "$LOCK_FILE/info"
}

release_lock() {
  rm -rf "$LOCK_FILE"
}

trap release_lock EXIT

# -- Merge a single branch ----------------------------------------------
# Args: $1=branch name  Returns: 0=success 1=fail 2=abort
merge_one() {
  local BRANCH="$1"
  info "Merging branch: $BRANCH"

  if git merge --no-edit "$BRANCH" 2>/dev/null; then
    ok "Merge successful: $BRANCH"
    return 0
  else
    fail "Merge conflict: $BRANCH"
    echo "  Conflicted files:"
    git diff --name-only --diff-filter=U 2>/dev/null | sed 's/^/    /'
    echo ""
    echo "  Options:"
    echo "    1) Resolve manually (in another terminal, then press Enter)"
    echo "    2) Skip this branch"
    echo "    3) Abort (rollback all merges)"
    if [ -t 0 ]; then
      read -rp "  Choice [1/2/3]: " CHOICE
    else
      warn "Non-interactive mode, auto-aborting"
      CHOICE="3"
    fi

    case "$CHOICE" in
      1)
        echo "  Resolve conflicts then press Enter..."
        read -r
        if git diff --name-only --diff-filter=U 2>/dev/null | grep -q .; then
          fail "Still have unresolved conflicts, skipping"
          git merge --abort 2>/dev/null || true
          return 1
        fi
        git add -A && git commit --no-edit
        ok "Conflicts resolved: $BRANCH"
        return 0
        ;;
      2)
        git merge --abort 2>/dev/null || true
        warn "Skipped: $BRANCH"
        return 1
        ;;
      3|*)
        git merge --abort 2>/dev/null || true
        return 2  # special return: abort all
        ;;
    esac
  fi
}

# -- Clean up merged branch and worktree --------------------------------
cleanup_branch() {
  local BRANCH="$1"
  WT_PATH=$(git worktree list --porcelain | grep -B2 "branch refs/heads/$BRANCH" | grep "^worktree " | sed 's/^worktree //')
  if [ -n "$WT_PATH" ]; then
    git worktree remove "$WT_PATH" --force 2>/dev/null && ok "Cleaned worktree: $WT_PATH" || warn "Manual cleanup needed: git worktree remove $WT_PATH"
  fi
  git branch -d "$BRANCH" 2>/dev/null && ok "Deleted branch: $BRANCH" || true
}

# ======================================================================
#  Main logic
# ======================================================================

echo ""
echo "=========================================="
echo "  Worktree Finish (merge only)"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

MAIN_BRANCH=$(cd "$MAIN_DIR" && git symbolic-ref --short HEAD 2>/dev/null)
MODE="single"
[ "$1" = "--all" ] && MODE="batch"
[ "$1" = "--sync" ] && MODE="sync"

# -- Sync mode (--sync) ------------------------------------------------
# Rebase worktree branch onto latest main before starting work
if [ "$MODE" = "sync" ]; then
  CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)
  if [ -z "$CURRENT_BRANCH" ] || [ "$CURRENT_BRANCH" = "$MAIN_BRANCH" ]; then
    warn "Not on a worktree branch, nothing to sync"
    exit 0
  fi

  BEHIND=$(git rev-list --count HEAD.."$MAIN_BRANCH" 2>/dev/null || echo 0)
  if [ "$BEHIND" = "0" ]; then
    ok "Already in sync with $MAIN_BRANCH (no commits behind)"
    exit 0
  fi

  info "Branch $CURRENT_BRANCH is $BEHIND commits behind $MAIN_BRANCH, rebasing..."

  HAS_CHANGES=false
  if ! git diff --quiet || ! git diff --cached --quiet; then
    HAS_CHANGES=true
    info "Stashing uncommitted changes..."
    git stash push -m "finish.sh --sync auto-stash" --include-untracked
  fi

  if git rebase "$MAIN_BRANCH" 2>&1; then
    ok "Rebase successful, now in sync with $MAIN_BRANCH"
  else
    fail "Rebase conflict, aborting"
    git rebase --abort 2>/dev/null || true
    if [ "$HAS_CHANGES" = true ]; then
      git stash pop 2>/dev/null || true
    fi
    exit 1
  fi

  if [ "$HAS_CHANGES" = true ]; then
    info "Restoring uncommitted changes..."
    git stash pop
  fi
  exit 0
fi

# -- Batch mode (--all) ------------------------------------------------
if [ "$MODE" = "batch" ]; then
  cd "$MAIN_DIR"

  CURRENT=$(git symbolic-ref --short HEAD 2>/dev/null)
  if [ "$CURRENT" != "$MAIN_BRANCH" ]; then
    fail "Please run --all from the main branch in the main directory"
    exit 1
  fi
  if ! git diff --quiet || ! git diff --cached --quiet; then
    fail "Working directory has uncommitted changes"
    exit 1
  fi

  # Discover branches
  BRANCHES=()
  while IFS= read -r line; do
    BRANCH=$(echo "$line" | grep -oP '\[.*?\]' | tr -d '[]')
    if [ -n "$BRANCH" ] && [ "$BRANCH" != "$MAIN_BRANCH" ]; then
      BRANCHES+=("$BRANCH")
    fi
  done < <(git worktree list)

  while IFS= read -r branch; do
    branch=$(echo "$branch" | sed 's/^[* ]*//' | xargs)
    if [ "$branch" != "$MAIN_BRANCH" ] && [[ ! " ${BRANCHES[*]} " =~ " $branch " ]]; then
      BRANCHES+=("$branch")
    fi
  done < <(git branch --list 'claude/*')

  if [ ${#BRANCHES[@]} -eq 0 ]; then
    warn "No branches to merge"
    exit 0
  fi

  echo ""
  echo "  Found ${#BRANCHES[@]} branches:"
  for i in "${!BRANCHES[@]}"; do
    B="${BRANCHES[$i]}"
    C=$(git log "$MAIN_BRANCH".."$B" --oneline 2>/dev/null | wc -l | xargs)
    BEHIND=$(git rev-list --count "$B".."$MAIN_BRANCH" 2>/dev/null || echo 0)
    S=$(git diff --stat "$MAIN_BRANCH"..."$B" 2>/dev/null | tail -1)
    if [ "$BEHIND" -gt 10 ]; then
      echo -e "  $((i+1)). $B  ($C commits, $S) ${YELLOW}WARNING: ${BEHIND} commits behind main${NC}"
    else
      echo "  $((i+1)). $B  ($C commits, $S)"
    fi
  done

  HAS_STALE=false
  for B in "${BRANCHES[@]}"; do
    BEHIND=$(git rev-list --count "$B".."$MAIN_BRANCH" 2>/dev/null || echo 0)
    if [ "$BEHIND" -gt 10 ]; then
      HAS_STALE=true
      break
    fi
  done
  if [ "$HAS_STALE" = true ]; then
    echo ""
    warn "Some branches are significantly behind main; batch merge may cause semantic conflicts"
    echo "  Suggestion: use single-branch mode to finish each one (auto-rebases)"
  fi

  echo ""
  echo "Enter numbers to merge (space-separated, Enter=all):"
  read -r SELECTION
  if [ -z "$SELECTION" ]; then
    SELECTED=("${BRANCHES[@]}")
  else
    SELECTED=()
    for idx in $SELECTION; do
      i=$((idx - 1))
      [ $i -ge 0 ] && [ $i -lt ${#BRANCHES[@]} ] && SELECTED+=("${BRANCHES[$i]}")
    done
  fi

  [ ${#SELECTED[@]} -eq 0 ] && { warn "No branches selected"; exit 0; }

  acquire_lock "batch-merge"
  ROLLBACK_POINT=$(git rev-parse HEAD)
  info "Rollback point: $(git log --oneline -1 HEAD)"

  MERGED=()
  FAILED=()
  for BRANCH in "${SELECTED[@]}"; do
    echo "----------------------------------------------"
    merge_one "$BRANCH"
    RET=$?
    if [ $RET -eq 0 ]; then
      MERGED+=("$BRANCH")
    elif [ $RET -eq 2 ]; then
      info "Rolling back all merges..."
      git reset --hard "$ROLLBACK_POINT"
      warn "Aborted"
      exit 1
    else
      FAILED+=("$BRANCH")
    fi
  done

  [ ${#MERGED[@]} -eq 0 ] && { warn "No branches merged successfully"; exit 1; }

  # Cleanup
  info "Cleaning up merged branches..."
  for B in "${MERGED[@]}"; do
    cleanup_branch "$B"
  done

  echo ""
  ok "Done! Merged: ${MERGED[*]}"
  [ ${#FAILED[@]} -gt 0 ] && warn "Skipped: ${FAILED[*]}"
  echo "  Deploy: bash deploy.sh"
  echo "  Rollback: git reset --hard $ROLLBACK_POINT"
  exit 0
fi

# -- Single branch mode (called from inside a worktree) ----------------
CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)

if [ -z "$CURRENT_BRANCH" ]; then
  fail "Cannot determine current branch"
  exit 1
fi

if [ "$CURRENT_BRANCH" = "$MAIN_BRANCH" ]; then
  fail "Already on main branch ($MAIN_BRANCH)"
  echo "  From a worktree branch: bash finish.sh"
  echo "  Batch merge:            bash finish.sh --all"
  exit 1
fi

info "Current branch: $CURRENT_BRANCH -> target: $MAIN_BRANCH"

# Ensure everything is committed
if ! git diff --quiet || ! git diff --cached --quiet; then
  fail "Uncommitted changes found, please commit first"
  exit 1
fi

COMMIT_COUNT=$(git log "$MAIN_BRANCH".."$CURRENT_BRANCH" --oneline 2>/dev/null | wc -l | xargs)
if [ "$COMMIT_COUNT" = "0" ]; then
  warn "No new commits, nothing to merge"
  exit 0
fi

info "Branch has $COMMIT_COUNT commits"

WORKTREE_DIR="$(pwd)"

# -- Step 0: Pre-flight rebase (outside lock, allows conflict resolution) --
info "Pre-flight rebase onto $MAIN_BRANCH..."
cd "$WORKTREE_DIR"
if ! git rebase "$MAIN_BRANCH" 2>&1; then
  fail "Rebase conflict! Resolve in current worktree, then re-run finish.sh"
  echo ""
  echo "  Conflicted files:"
  git diff --name-only --diff-filter=U 2>/dev/null | sed 's/^/    /'
  echo ""
  echo "  Resolution steps:"
  echo "    1. Edit conflicted files"
  echo "    2. git add <files>"
  echo "    3. git rebase --continue"
  echo "    4. Re-run finish.sh"
  exit 1
fi
ok "Pre-flight rebase successful"

# Acquire lock
acquire_lock "$CURRENT_BRANCH"
ok "Merge lock acquired"

# -- Step 1: Re-rebase (inside lock, handle changes during wait) -------
info "Re-rebase onto $MAIN_BRANCH (ensuring latest)..."
cd "$WORKTREE_DIR"
if ! git rebase "$MAIN_BRANCH" 2>&1; then
  fail "Rebase conflict after lock wait, resolve and retry"
  git rebase --abort 2>/dev/null || true
  exit 1
fi
ok "Re-rebase successful"

# -- Step 2: Pre-validate in worktree ----------------------------------
source "$MAIN_DIR/scripts/deploy-patterns.sh"
CHANGED_FILES=$(cd "$WORKTREE_DIR" && git diff --name-only "$MAIN_BRANCH".."$CURRENT_BRANCH" 2>/dev/null || echo "")
NEEDS_BUILD=true

if [ -n "$CHANGED_FILES" ]; then
  DEPLOY_CLASS=$(classify_changes "$CHANGED_FILES")
  if [ "$DEPLOY_CLASS" = "none" ]; then
    NEEDS_BUILD=false
    info "Changed files do not affect runtime, skipping pre-validation:"
    echo "$CHANGED_FILES" | sed 's/^/  /'
  fi
fi

if [ "$NEEDS_BUILD" = true ]; then
  info "Pre-validating in worktree (build + test:unit)..."

  cd "$WORKTREE_DIR"
  if ! run_silent "Build" npm run build; then
    fail "Pre-validation failed: build errors (main is unaffected)"
    exit 1
  fi

  if ! run_silent "Unit tests" npm run test:unit; then
    fail "Pre-validation failed: test errors (main is unaffected)"
    exit 1
  fi
  ok "Pre-validation passed"
fi

# -- Step 3: Fast-forward merge to main --------------------------------
cd "$MAIN_DIR"
ROLLBACK_POINT=$(git rev-parse HEAD)
info "Rollback point: $(git log --oneline -1 HEAD)"

if ! git merge --ff-only "$CURRENT_BRANCH" 2>&1; then
  fail "Fast-forward merge failed (should not happen after rebase)"
  exit 1
fi
ok "Fast-forward merge successful"

# (Optional: post-merge sync hook)
# Add project-specific sync logic here if needed.

# Sync origin/main tracking ref (origin points to self; new worktrees depend on this)
git push origin "$MAIN_BRANCH" 2>/dev/null && info "origin/$MAIN_BRANCH synced" || true

echo ""
echo "=========================================="
echo -e "  ${GREEN}Done!${NC}"
echo "  Branch $CURRENT_BRANCH merged to $MAIN_BRANCH"
if [ "$NEEDS_BUILD" = true ]; then
  echo "  Deploy: cd $MAIN_DIR && bash deploy.sh"
fi
echo "  You can continue working in this worktree, commit, and finish again"
echo "  Rollback: cd $MAIN_DIR && git reset --hard $ROLLBACK_POINT"
echo "=========================================="

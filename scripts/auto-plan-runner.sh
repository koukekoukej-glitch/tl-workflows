#!/usr/bin/env bash
# ===================================================================
# auto-plan-runner.sh -- Unattended batch plan execution loop
#
# Reads a structured plan file (Markdown with task IDs), spawns
# Claude Code sessions one task at a time, runs verification commands,
# invokes a Review Agent, and produces a summary report.
#
# Usage:
#   bash scripts/auto-plan-runner.sh <plan-name>
#   bash scripts/auto-plan-runner.sh my-plan --dry-run
#   bash scripts/auto-plan-runner.sh my-plan --start-from P0.3
#   bash scripts/auto-plan-runner.sh my-plan --max-tasks 3
#   bash scripts/auto-plan-runner.sh my-plan --task-timeout 900
#   bash scripts/auto-plan-runner.sh my-plan --max-failures 3
#   bash scripts/auto-plan-runner.sh my-plan --checkpoint
#
# Environment variables:
#   MODEL=sonnet|opus       Model (default: opus)
#   MAX_TURNS=N             Max turns per task (default: 200)
#   PAUSE_BETWEEN=N         Seconds between tasks (default: 10)
#   NO_FINISH=1             Skip /finish step (debug)
#   NO_REVIEW=1             Skip Review Agent
#   BUDGET_PER_TASK=N       Per-task budget USD (default: 10)
# ===================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TODO_DIR="$REPO_ROOT/data/todo"
LOG_DIR="$REPO_ROOT/data/auto-run-logs"
STATE_FILE="$REPO_ROOT/data/.auto-runner-state"
PARSER="$REPO_ROOT/scripts/parse-plan-task.js"

PLAN_NAME="${1:?Usage: bash scripts/auto-plan-runner.sh <plan-name>}"
shift

DRY_RUN=false; START_FROM=""; MAX_TASKS=0; TASK_TIMEOUT=1800; MAX_FAILURES=2; CHECKPOINT=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)        DRY_RUN=true; shift ;;
    --start-from)     START_FROM="$2"; shift 2 ;;
    --max-tasks)      MAX_TASKS="$2"; shift 2 ;;
    --task-timeout)   TASK_TIMEOUT="$2"; shift 2 ;;
    --max-failures)   MAX_FAILURES="$2"; shift 2 ;;
    --checkpoint)     CHECKPOINT=true; shift ;;
    --no-checkpoint)  CHECKPOINT=false; shift ;;
    *)                echo "Unknown argument: $1"; exit 1 ;;
  esac
done

MODEL="${MODEL:-opus}"; MAX_TURNS="${MAX_TURNS:-200}"
PAUSE_BETWEEN="${PAUSE_BETWEEN:-10}"; NO_FINISH="${NO_FINISH:-0}"
NO_REVIEW="${NO_REVIEW:-0}"; BUDGET_PER_TASK="${BUDGET_PER_TASK:-10}"
PLAN_FILE="$TODO_DIR/${PLAN_NAME}.md"

[[ ! -f "$PLAN_FILE" ]] && echo "Plan not found: $PLAN_FILE" && exit 1
[[ ! -f "$PARSER" ]] && echo "Parser not found: $PARSER" && exit 1
mkdir -p "$LOG_DIR"

C='\033[0;36m'; G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; B='\033[1m'; N='\033[0m'
log()  { echo -e "${C}[$(date +%H:%M:%S)]${N} $*"; }
ok()   { echo -e "${G}[$(date +%H:%M:%S)]${N} $*"; }
warn() { echo -e "${Y}[$(date +%H:%M:%S)] WARN${N} $*"; }
err()  { echo -e "${R}[$(date +%H:%M:%S)] FAIL${N} $*"; }

# =============== Prompt builders ===============

build_prompt() {
  local tid="$1" ttitle="$2" tcontent="$3" verify_cmds="$4"
  local finish_block=""
  [[ "$NO_FINISH" != "1" ]] && finish_block="
## Step 3: Finish
After all verifications pass, invoke /finish (Skill tool, skill=finish).
This handles: commit, merge to main, deploy, plan progress update."

  local verify_block=""
  if [[ -n "$verify_cmds" ]]; then
    verify_block="

## Verification gate (must pass before /finish)
The following commands must all succeed (exit code 0) before /finish:
${verify_cmds}
If any fail, fix the code and re-verify."
  fi

  echo "You are executing task ${tid} of the ${PLAN_NAME} plan. This is an automated pipeline -- do not wait for user input.

## Step 1: Understand context
1. Read the full plan file: ${PLAN_FILE}
2. Understand the overall architecture and the current task's position
3. Check outputs from prerequisite tasks (if any)

## Step 2: Execute task
Current task: **${tid} -- ${ttitle}**

${tcontent}

Complete all checklist items. Then run the **verification** steps from the task.
All verifications must pass. Fix and re-verify on failure.
${verify_block}
${finish_block}
## Constraints
- Unattended execution -- do not ask questions or wait for input
- Make autonomous decisions based on the plan design notes
- If blocked, write details to ${LOG_DIR}/${tid}-error.md and exit
- Code quality: must compile, tests pass, follows project style"
}

build_fix_prompt() {
  local tid="$1" ttitle="$2" tcontent="$3" verify_output="$4" failed_cmd="$5"
  echo "You are fixing a verification failure for task ${tid} of the ${PLAN_NAME} plan. Automated pipeline -- no user input.

## Background
Task ${tid} -- ${ttitle} code is complete and merged to main, but the runner verification command failed.

## Failed verification command
\`\`\`
${failed_cmd}
\`\`\`

## Failure output
\`\`\`
${verify_output}
\`\`\`

## Original task description
${tcontent}

## Your task
1. Read the plan file for context: ${PLAN_FILE}
2. Analyze the verification failure
3. Fix the code so the verification command passes
4. Invoke /finish (Skill tool, skill=finish) to merge the fix

## Constraints
- Unattended execution -- do not ask questions
- Only fix the verification failure, do not change unrelated code
- Verify locally before finishing"
}

# =============== Review Agent ===============

build_review_prompt() {
  local task_content="$1" git_diff="$2"
  echo "You are a code reviewer. Determine whether the following diff satisfies the spec exit criteria.

## Spec (task requirements)
${task_content}

## Diff (actual changes)
${git_diff}

## Criteria
1. Is every exit criterion satisfied?
2. Are there unintended side effects not mentioned in the spec?
3. Are there obvious quality issues (unhandled errors, hardcoded values, type unsafety)?

## Output format (follow strictly)
VERDICT: PASS | WARN | FAIL
ITEMS:
- [PASS|WARN|FAIL] {specific item}
SUMMARY: {one-sentence summary}"
}

build_review_fix_prompt() {
  local tid="$1" ttitle="$2" tcontent="$3" review_output="$4"
  echo "You are fixing a Review Agent failure for task ${tid} of the ${PLAN_NAME} plan. Automated pipeline -- no user input.

## Background
Task ${tid} -- ${ttitle} code is complete and passed verification commands, but the Review Agent found it does not meet exit criteria.

## Review Agent output
${review_output}

## Original task description
${tcontent}

## Your task
1. Read the plan file for context: ${PLAN_FILE}
2. Analyze the Review Agent's findings
3. Fix the code to satisfy all exit criteria
4. Invoke /finish (Skill tool, skill=finish) to merge the fix

## Constraints
- Unattended execution -- do not ask questions
- Only fix issues raised by the Review Agent
- Self-verify exit criteria after fixing"
}

# Run Review Agent and parse verdict
# Sets global: REVIEW_VERDICT, REVIEW_OUTPUT
REVIEW_VERDICT=""
REVIEW_OUTPUT=""

run_review_agent() {
  local task_content="$1" git_diff="$2" log_prefix="$3"
  REVIEW_VERDICT=""
  REVIEW_OUTPUT=""

  local review_prompt
  review_prompt=$(build_review_prompt "$task_content" "$git_diff")
  local review_log="${log_prefix}-review.json"

  log "Starting Review Agent (opus, max-turns=3, budget=\$3)..."

  set +e
  local raw_output
  raw_output=$(claude -p "$review_prompt" \
    --model opus \
    --max-turns 3 \
    --max-budget-usd 3 \
    --dangerously-skip-permissions \
    --output-format text \
    2>"${review_log%.json}.stderr")
  local review_exit=$?
  set -e

  echo "$raw_output" > "$review_log"

  if [[ $review_exit -ne 0 ]]; then
    warn "Review Agent error (exit=$review_exit), treating as PASS"
    REVIEW_VERDICT="PASS"
    REVIEW_OUTPUT="Review Agent error (exit=$review_exit)"
    return 0
  fi

  REVIEW_OUTPUT="$raw_output"

  local verdict_line
  verdict_line=$(echo "$raw_output" | grep -oP 'VERDICT:\s*\K(PASS|WARN|FAIL)' | head -1 || true)

  if [[ -z "$verdict_line" ]]; then
    warn "No VERDICT found in Review Agent output, treating as PASS"
    REVIEW_VERDICT="PASS"
    return 0
  fi

  REVIEW_VERDICT="$verdict_line"
  return 0
}

# =============== Cost extraction from JSON logs ===============

extract_cost() {
  local log_file="$1"
  node -e "
    const lines=require('fs').readFileSync(process.argv[1],'utf8').trim().split('\n');
    for(const l of lines){
      try{
        const d=JSON.parse(l);
        if(d.cost_usd!==undefined){console.log(d.cost_usd);process.exit(0);}
        if(d.costUsd!==undefined){console.log(d.costUsd);process.exit(0);}
        if(d.total_cost_usd!==undefined){console.log(d.total_cost_usd);process.exit(0);}
        if(d.session_cost!==undefined){console.log(d.session_cost);process.exit(0);}
      }catch(e){}
    }
    console.log('N/A');
  " "$log_file" 2>/dev/null || echo "N/A"
}

# =============== Verification commands ===============

VERIFY_FAILED_CMD=""
VERIFY_FAILED_OUTPUT=""

run_verify_commands() {
  local commands="$1"
  local work_dir="$2"
  VERIFY_FAILED_CMD=""
  VERIFY_FAILED_OUTPUT=""

  while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    log "  Verify: $cmd"
    local output
    set +e
    output=$(cd "$work_dir" && eval "$cmd" 2>&1)
    local cmd_exit=$?
    set -e

    if [[ $cmd_exit -ne 0 ]]; then
      err "  Verification failed (exit=$cmd_exit): $cmd"
      VERIFY_FAILED_CMD="$cmd"
      VERIFY_FAILED_OUTPUT=$(echo "$output" | tail -100)
      return 1
    else
      ok "  Verification passed: $cmd"
    fi
  done <<< "$commands"

  return 0
}

# =============== Summary report ===============

declare -a TASK_RESULTS=()
RUN_START_EPOCH=$(date +%s)

# Record task result: add_task_result ID TITLE STATUS DURATION COST LINES COMMIT WARN REVIEW_VERDICT REVIEW_ROUNDS PHASE
add_task_result() {
  local id="$1" title="$2" status="$3" duration="$4" cost="$5" lines="$6" commit="$7" warn_msg="${8:-}" review_verdict="${9:-}" review_rounds="${10:-0}" phase="${11:-}"
  TASK_RESULTS+=("${id}|${title}|${status}|${duration}|${cost}|${lines}|${commit}|${warn_msg}|${review_verdict}|${review_rounds}|${phase}")
}

generate_summary() {
  local run_end_epoch
  run_end_epoch=$(date +%s)
  local total_duration=$(( run_end_epoch - RUN_START_EPOCH ))
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  local summary_file="$LOG_DIR/${PLAN_NAME}-${ts}-summary.md"

  local pass_count=0 fail_count=0 warn_count=0 timeout_count=0
  local total_cost=0 total_lines=0

  local review_pass=0 review_warn=0 review_fail=0 review_skip=0

  local -a phase_order=()
  local -A phase_seen=()

  for entry in "${TASK_RESULTS[@]}"; do
    IFS='|' read -r id title status duration cost lines commit warn_msg review_verdict review_rounds phase <<< "$entry"
    case "$status" in
      PASS)    pass_count=$((pass_count + 1)) ;;
      FAIL)    fail_count=$((fail_count + 1)) ;;
      TIMEOUT) timeout_count=$((timeout_count + 1)); fail_count=$((fail_count + 1)) ;;
    esac
    [[ -n "$warn_msg" ]] && warn_count=$((warn_count + 1))
    if [[ "$cost" != "N/A" ]]; then
      total_cost=$(echo "$total_cost + $cost" | bc 2>/dev/null || echo "$total_cost")
    fi
    if [[ "$lines" != "N/A" && "$lines" =~ ^[0-9]+$ ]]; then
      total_lines=$((total_lines + lines))
    fi
    case "$review_verdict" in
      PASS) review_pass=$((review_pass + 1)) ;;
      WARN) review_warn=$((review_warn + 1)) ;;
      FAIL) review_fail=$((review_fail + 1)) ;;
      *)    review_skip=$((review_skip + 1)) ;;
    esac
    local ph="${phase:-_none_}"
    if [[ -z "${phase_seen[$ph]:-}" ]]; then
      phase_order+=("$ph")
      phase_seen[$ph]=1
    fi
  done

  local dur_min=$((total_duration / 60))
  local dur_sec=$((total_duration % 60))

  {
    echo "# Execution Summary: ${PLAN_NAME}"
    echo ""
    echo "**Time**: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "**Duration**: ${dur_min}m${dur_sec}s"
    echo ""
    echo "## Statistics"
    echo ""
    echo "| Metric | Value |"
    echo "|--------|-------|"
    echo "| Pass | $pass_count |"
    echo "| Fail | $fail_count |"
    [[ $timeout_count -gt 0 ]] && echo "| Timeout | $timeout_count |"
    echo "| WARN | $warn_count |"
    echo "| Review PASS | $review_pass |"
    echo "| Review WARN | $review_warn |"
    echo "| Review FAIL | $review_fail |"
    [[ $review_skip -gt 0 ]] && echo "| Review Skipped | $review_skip |"
    echo "| Total Cost | \$${total_cost} |"
    echo "| Total Lines | $total_lines |"
    echo "| Total Duration | ${dur_min}m${dur_sec}s |"
    echo ""

    local has_phases=false
    if [[ ${#phase_order[@]} -gt 1 || ( ${#phase_order[@]} -eq 1 && "${phase_order[0]}" != "_none_" ) ]]; then
      has_phases=true
    fi

    if $has_phases; then
      echo "## Phase Statistics"
      echo ""
      echo "| Phase | Pass | Fail | WARN | Review | Cost | Lines |"
      echo "|-------|------|------|------|--------|------|-------|"

      for ph in "${phase_order[@]}"; do
        local ph_pass=0 ph_fail=0 ph_warn=0 ph_cost=0 ph_lines=0
        local ph_display="$ph"
        [[ "$ph" == "_none_" ]] && ph_display="(ungrouped)"

        for entry in "${TASK_RESULTS[@]}"; do
          IFS='|' read -r id title status duration cost lines commit warn_msg review_verdict review_rounds phase <<< "$entry"
          local entry_ph="${phase:-_none_}"
          [[ "$entry_ph" != "$ph" ]] && continue

          case "$status" in
            PASS)    ph_pass=$((ph_pass + 1)) ;;
            FAIL|TIMEOUT) ph_fail=$((ph_fail + 1)) ;;
          esac
          [[ -n "$warn_msg" ]] && ph_warn=$((ph_warn + 1))
          if [[ "$cost" != "N/A" ]]; then
            ph_cost=$(echo "$ph_cost + $cost" | bc 2>/dev/null || echo "$ph_cost")
          fi
          if [[ "$lines" != "N/A" && "$lines" =~ ^[0-9]+$ ]]; then
            ph_lines=$((ph_lines + lines))
          fi
        done

        echo "| $ph_display | $ph_pass | $ph_fail | $ph_warn | - | \$${ph_cost} | $ph_lines |"
      done
      echo ""
    fi

    echo "## Task Results"
    echo ""

    if $has_phases; then
      for ph in "${phase_order[@]}"; do
        local ph_display="$ph"
        [[ "$ph" == "_none_" ]] && ph_display="(ungrouped)"
        echo "### $ph_display"
        echo ""
        echo "| ID | Title | Duration | Cost | Lines | Commit | Review | Status |"
        echo "|---|---|---|---|---|---|---|---|"

        for entry in "${TASK_RESULTS[@]}"; do
          IFS='|' read -r id title status duration cost lines commit warn_msg review_verdict review_rounds phase <<< "$entry"
          local entry_ph="${phase:-_none_}"
          [[ "$entry_ph" != "$ph" ]] && continue

          local task_dur_min=$((duration / 60))
          local task_dur_sec=$((duration % 60))
          local status_display="$status"
          [[ -n "$warn_msg" ]] && status_display="${status}+WARN"
          local review_display="${review_verdict:-N/A}"
          [[ "$review_rounds" -gt 1 ]] && review_display="${review_verdict}(${review_rounds} rounds)"
          echo "| $id | $title | ${task_dur_min}m${task_dur_sec}s | \$${cost} | $lines | ${commit:0:7} | $review_display | $status_display |"
        done
        echo ""
      done
    else
      echo "| ID | Title | Duration | Cost | Lines | Commit | Review | Status |"
      echo "|---|---|---|---|---|---|---|---|"

      for entry in "${TASK_RESULTS[@]}"; do
        IFS='|' read -r id title status duration cost lines commit warn_msg review_verdict review_rounds phase <<< "$entry"
        local task_dur_min=$((duration / 60))
        local task_dur_sec=$((duration % 60))
        local status_display="$status"
        [[ -n "$warn_msg" ]] && status_display="${status}+WARN"
        local review_display="${review_verdict:-N/A}"
        [[ "$review_rounds" -gt 1 ]] && review_display="${review_verdict}(${review_rounds} rounds)"
        echo "| $id | $title | ${task_dur_min}m${task_dur_sec}s | \$${cost} | $lines | ${commit:0:7} | $review_display | $status_display |"
      done
      echo ""
    fi

    echo ""
    echo "## Anomalies"
    echo ""

    local has_anomaly=false
    for entry in "${TASK_RESULTS[@]}"; do
      IFS='|' read -r id title status duration cost lines commit warn_msg review_verdict review_rounds phase <<< "$entry"
      if [[ "$duration" -gt 1200 ]]; then
        local ad=$((duration / 60))
        echo "- **$id** High duration (${ad}m)"
        has_anomaly=true
      fi
      if [[ -n "$commit" && "$commit" != "N/A" ]]; then
        local file_count
        file_count=$(git -C "$REPO_ROOT" diff --name-only "${commit}^".."$commit" 2>/dev/null | wc -l || echo "0")
        if [[ "$file_count" -gt 10 ]]; then
          echo "- **$id** High file count (${file_count} files)"
          has_anomaly=true
        fi
      fi
      if [[ "$warn_msg" == *"empty-diff"* ]]; then
        echo "- **$id** Empty diff: task completed with no code changes"
        has_anomaly=true
      fi
      if [[ "$review_verdict" == "WARN" ]]; then
        echo "- **$id** Review WARN: see $LOG_DIR/${id}-*-review.json"
        has_anomaly=true
      fi
      if [[ "$review_verdict" == "FAIL" ]]; then
        echo "- **$id** Review FAIL (${review_rounds} rounds): see $LOG_DIR/${id}-*-review.json"
        has_anomaly=true
      fi
      if [[ "$status" == "FAIL" || "$status" == "TIMEOUT" ]]; then
        echo "- **$id** ${status}: see $LOG_DIR/${id}-*.json"
        has_anomaly=true
      fi
    done
    $has_anomaly || echo "_No anomalies_"

    echo ""
    echo "---"
    echo ""
    echo "Run \`/vibe review ${PLAN_NAME}\` for improvement suggestions."
  } > "$summary_file"

  ok "Summary report: $summary_file"
}

# =============== Main loop ===============

echo ""
echo -e "${B}===================================================${N}"
echo -e "${B}  Auto Plan Runner -- ${PLAN_NAME}${N}"
echo -e "${B}===================================================${N}"
echo ""
log "Plan: $PLAN_FILE"
log "Model: $MODEL | turns: $MAX_TURNS | budget: \$${BUDGET_PER_TASK}/task"
log "Timeout: ${TASK_TIMEOUT}s | max consecutive failures: $MAX_FAILURES"
$DRY_RUN && warn "DRY RUN mode"
$CHECKPOINT && log "Phase checkpoints: enabled"
[[ "$NO_REVIEW" == "1" ]] && warn "Skipping Review Agent (NO_REVIEW=1)"
[[ -n "$START_FROM" ]] && log "Starting from $START_FROM"
[[ "$MAX_TASKS" -gt 0 ]] && log "Max tasks: $MAX_TASKS"
echo ""

completed=0; failed=0; consecutive_failures=0; iteration=0
LAST_COMPLETED_ID=""
CURRENT_PHASE=""
echo "started:$(date -Iseconds):plan=$PLAN_NAME" > "$STATE_FILE"

while true; do
  iteration=$((iteration + 1))
  [[ "$MAX_TASKS" -gt 0 && "$completed" -ge "$MAX_TASKS" ]] && { log "Reached limit ($MAX_TASKS)"; break; }

  # Circuit breaker: consecutive failures
  if [[ "$consecutive_failures" -ge "$MAX_FAILURES" ]]; then
    err "Hit $consecutive_failures consecutive failures, circuit breaker triggered (--max-failures $MAX_FAILURES)"
    break
  fi

  # Build parser arguments
  PARSER_ARGS=("$PLAN_FILE")
  if [[ -n "$START_FROM" ]]; then
    PARSER_ARGS+=("--start-from" "$START_FROM")
  elif [[ -n "$LAST_COMPLETED_ID" ]]; then
    PARSER_ARGS+=("--skip-past" "$LAST_COMPLETED_ID")
  fi

  set +e
  TASK_OUTPUT=$(node "$PARSER" "${PARSER_ARGS[@]}" 2>/dev/null)
  PARSE_EXIT=$?
  set -e

  [[ $PARSE_EXIT -ne 0 ]] && { ok "All tasks complete!"; break; }

  TASK_ID=$(echo "$TASK_OUTPUT" | head -1)
  TASK_TITLE=$(echo "$TASK_OUTPUT" | sed -n '2p')
  TASK_CONTENT=$(echo "$TASK_OUTPUT" | tail -n +3)

  # Get verification commands via JSON mode
  set +e
  TASK_JSON=$(node "$PARSER" "${PARSER_ARGS[@]}" --json 2>/dev/null)
  set -e
  VERIFY_COMMANDS=""
  TASK_PHASE=""
  if [[ -n "$TASK_JSON" ]]; then
    VERIFY_COMMANDS=$(echo "$TASK_JSON" | node -e "
      let buf='';
      process.stdin.on('data',d=>buf+=d);
      process.stdin.on('end',()=>{
        try{
          const data=JSON.parse(buf);
          if(data.verifyCommands&&data.verifyCommands.length>0){
            data.verifyCommands.forEach(cmd=>console.log(cmd));
          }
        }catch(e){}
      });
    " 2>/dev/null || true)
    TASK_PHASE=$(echo "$TASK_JSON" | node -e "
      let buf='';
      process.stdin.on('data',d=>buf+=d);
      process.stdin.on('end',()=>{
        try{
          const data=JSON.parse(buf);
          if(data.phase){console.log(data.phase);}
        }catch(e){}
      });
    " 2>/dev/null || true)
  fi

  # Build verification commands text for prompt
  VERIFY_PROMPT_BLOCK=""
  if [[ -n "$VERIFY_COMMANDS" ]]; then
    VERIFY_PROMPT_BLOCK=$(echo "$VERIFY_COMMANDS" | while IFS= read -r cmd; do
      [[ -n "$cmd" ]] && echo "- \`$cmd\`"
    done)
  fi

  # =============== Phase checkpoint ===============
  if $CHECKPOINT && [[ -n "$TASK_PHASE" && "$TASK_PHASE" != "$CURRENT_PHASE" && -n "$CURRENT_PHASE" ]]; then
    cp_pass=0; cp_total=0; cp_cost=0; cp_lines=0; cp_warns=""
    for entry in "${TASK_RESULTS[@]}"; do
      IFS='|' read -r _id _title _status _duration _cost _lines _commit _warn _rv _rr _phase <<< "$entry"
      [[ "${_phase:-}" != "$CURRENT_PHASE" ]] && continue
      cp_total=$((cp_total + 1))
      [[ "$_status" == "PASS" ]] && cp_pass=$((cp_pass + 1))
      if [[ "$_cost" != "N/A" ]]; then
        cp_cost=$(echo "$cp_cost + $_cost" | bc 2>/dev/null || echo "$cp_cost")
      fi
      if [[ "$_lines" != "N/A" && "$_lines" =~ ^[0-9]+$ ]]; then
        cp_lines=$((cp_lines + _lines))
      fi
      if [[ -n "$_warn" ]]; then
        cp_warns="${cp_warns}  WARN: ${_id} ${_warn}\n"
      fi
    done

    echo ""
    echo -e "${B}===========================================${N}"
    echo -e "${B} Phase complete: ${CURRENT_PHASE}${N}"
    echo -e "${B}-------------------------------------------${N}"
    echo -e " Tasks: ${cp_pass}/${cp_total} pass | Cost: \$${cp_cost} | Lines: ${cp_lines}"
    if [[ -n "$cp_warns" ]]; then
      echo -e "$cp_warns"
    fi
    echo -e "${B}===========================================${N}"

    if [[ -t 0 ]]; then
      read -p "Press Enter to continue to next Phase, or Ctrl+C to abort..."
    else
      log "(Non-interactive, skipping checkpoint pause)"
    fi
    echo ""
  fi
  [[ -n "$TASK_PHASE" ]] && CURRENT_PHASE="$TASK_PHASE"

  echo ""
  echo -e "${B}---------------------------------------------------${N}"
  log "[$iteration] ${C}${TASK_ID}${N} -- ${TASK_TITLE}"
  if [[ -n "$VERIFY_COMMANDS" ]]; then
    log "Verify commands: $(echo "$VERIFY_COMMANDS" | wc -l | tr -d ' ')"
  else
    log "Verify commands: none (skipping verification)"
  fi
  echo -e "${B}---------------------------------------------------${N}"

  if $DRY_RUN; then
    echo "$TASK_CONTENT" | head -8
    echo "  ..."
    if [[ -n "$VERIFY_COMMANDS" ]]; then
      log "[DRY RUN] Verify commands:"
      echo "$VERIFY_COMMANDS" | while IFS= read -r cmd; do
        [[ -n "$cmd" ]] && log "  - $cmd"
      done
    fi
    warn "[DRY RUN] Skipped"
    add_task_result "$TASK_ID" "$TASK_TITLE" "PASS" "0" "N/A" "N/A" "dry-run" "" "" "0" "$TASK_PHASE"
    completed=$((completed + 1))
    LAST_COMPLETED_ID="$TASK_ID"
    START_FROM=""
    continue
  fi

  PROMPT=$(build_prompt "$TASK_ID" "$TASK_TITLE" "$TASK_CONTENT" "$VERIFY_PROMPT_BLOCK")
  TS=$(date +%Y%m%d-%H%M%S)
  TASK_LOG_FILE="$LOG_DIR/${TASK_ID}-${TS}.json"
  TASK_START_EPOCH=$(date +%s)

  GIT_HEAD_BEFORE=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")

  echo "running:$(date -Iseconds):task=$TASK_ID" > "$STATE_FILE"
  log "Starting Claude Code (worktree, $MODEL, timeout=${TASK_TIMEOUT}s)..."

  cd "$REPO_ROOT"
  set +e
  timeout "$TASK_TIMEOUT" claude -p "$PROMPT" \
    -w \
    --dangerously-skip-permissions \
    --model "$MODEL" \
    --max-turns "$MAX_TURNS" \
    --max-budget-usd "$BUDGET_PER_TASK" \
    --output-format json \
    > "$TASK_LOG_FILE" 2>"${TASK_LOG_FILE%.json}.stderr"
  EXIT_CODE=$?
  set -e

  TASK_END_EPOCH=$(date +%s)
  TASK_DURATION=$((TASK_END_EPOCH - TASK_START_EPOCH))
  TASK_DURATION_MIN=$((TASK_DURATION / 60))

  TASK_COST="N/A"
  [[ -f "$TASK_LOG_FILE" ]] && TASK_COST=$(extract_cost "$TASK_LOG_FILE")

  GIT_HEAD_AFTER=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")
  LINES_CHANGED="N/A"
  COMMIT_HASH=""
  WARN_MSG=""

  if [[ "$GIT_HEAD_BEFORE" != "$GIT_HEAD_AFTER" && "$GIT_HEAD_AFTER" != "unknown" ]]; then
    COMMIT_HASH="$GIT_HEAD_AFTER"
    DIFF_STAT=$(git -C "$REPO_ROOT" diff --stat "$GIT_HEAD_BEFORE".."$GIT_HEAD_AFTER" 2>/dev/null | tail -1)
    if [[ -n "$DIFF_STAT" ]]; then
      INS=$(echo "$DIFF_STAT" | grep -oP '\d+(?= insertion)' || echo "0")
      DEL=$(echo "$DIFF_STAT" | grep -oP '\d+(?= deletion)' || echo "0")
      LINES_CHANGED=$(( ${INS:-0} + ${DEL:-0} ))
    fi
  fi

  # Timeout handling (exit code 124 from timeout command)
  if [[ $EXIT_CODE -eq 124 ]]; then
    err "${TASK_ID} timed out (${TASK_TIMEOUT}s / ${TASK_DURATION_MIN}m)"
    failed=$((failed + 1))
    consecutive_failures=$((consecutive_failures + 1))
    add_task_result "$TASK_ID" "$TASK_TITLE" "TIMEOUT" "$TASK_DURATION" "$TASK_COST" "$LINES_CHANGED" "$COMMIT_HASH" "" "" "0" "$TASK_PHASE"
    echo "timeout:$(date -Iseconds):task=$TASK_ID" > "$STATE_FILE"
    LAST_COMPLETED_ID="$TASK_ID"
    START_FROM=""
    continue
  fi

  if [[ $EXIT_CODE -eq 0 ]]; then
    RESULT=$(node -e "
      const lines=require('fs').readFileSync(process.argv[1],'utf8').trim().split('\n');
      for(const l of lines){try{const d=JSON.parse(l);if(d.result){console.log(d.result.substring(0,200));process.exit(0);}}catch(e){}}
    " "$TASK_LOG_FILE" 2>/dev/null || echo "")

    # Empty diff detection
    if [[ "$GIT_HEAD_BEFORE" == "$GIT_HEAD_AFTER" || "$LINES_CHANGED" == "0" || "$LINES_CHANGED" == "N/A" ]]; then
      warn "${TASK_ID} completed with no code changes (empty diff)"
      WARN_MSG="empty-diff"
    fi

    ok "${TASK_ID} done (${TASK_DURATION_MIN}m, \$${TASK_COST})"
    [[ -n "$RESULT" ]] && log "Summary: ${RESULT:0:120}..."

    # =============== Verification command gate ===============
    VERIFY_PASSED=true
    if [[ -n "$VERIFY_COMMANDS" ]]; then
      log "Running verification gate (${TASK_ID})..."
      if run_verify_commands "$VERIFY_COMMANDS" "$REPO_ROOT"; then
        ok "All verifications passed"
      else
        warn "Verification failed, spawning Fix Agent..."
        VERIFY_PASSED=false

        FIX_LOG_FILE="$LOG_DIR/${TASK_ID}-fix-${TS}.json"
        FIX_PROMPT=$(build_fix_prompt "$TASK_ID" "$TASK_TITLE" "$TASK_CONTENT" "$VERIFY_FAILED_OUTPUT" "$VERIFY_FAILED_CMD")

        set +e
        timeout "$TASK_TIMEOUT" claude -p "$FIX_PROMPT" \
          -w \
          --dangerously-skip-permissions \
          --model "$MODEL" \
          --max-turns "$MAX_TURNS" \
          --max-budget-usd "$BUDGET_PER_TASK" \
          --output-format json \
          > "$FIX_LOG_FILE" 2>"${FIX_LOG_FILE%.json}.stderr"
        FIX_EXIT=$?
        set -e

        if [[ $FIX_EXIT -eq 0 ]]; then
          log "Fix Agent done, re-verifying..."
          if run_verify_commands "$VERIFY_COMMANDS" "$REPO_ROOT"; then
            ok "Post-fix verification passed"
            VERIFY_PASSED=true
            GIT_HEAD_AFTER=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")
            [[ "$GIT_HEAD_AFTER" != "unknown" ]] && COMMIT_HASH="$GIT_HEAD_AFTER"
          else
            err "Post-fix verification still failing"
          fi
        else
          err "Fix Agent failed (exit=$FIX_EXIT)"
        fi
      fi
    fi

    if $VERIFY_PASSED; then
      # =============== Review Agent ===============
      TASK_REVIEW_VERDICT=""
      TASK_REVIEW_ROUNDS=0
      REVIEW_SKIPPED=false

      if [[ "$NO_REVIEW" == "1" ]]; then
        log "Skipping Review Agent (NO_REVIEW=1)"
        REVIEW_SKIPPED=true
      elif [[ "$WARN_MSG" == *"empty-diff"* ]]; then
        log "Skipping Review Agent (empty diff)"
        REVIEW_SKIPPED=true
      fi

      if ! $REVIEW_SKIPPED; then
        REVIEW_DIFF=$(git -C "$REPO_ROOT" diff main...HEAD 2>/dev/null || true)
        if [[ -z "$REVIEW_DIFF" ]]; then
          REVIEW_DIFF=$(git -C "$REPO_ROOT" diff "$GIT_HEAD_BEFORE".."$GIT_HEAD_AFTER" 2>/dev/null || true)
        fi

        if [[ -z "$REVIEW_DIFF" ]]; then
          log "No diff for Review, skipping"
          REVIEW_SKIPPED=true
        fi
      fi

      if ! $REVIEW_SKIPPED; then
        review_round=0
        MAX_REVIEW_ROUNDS=2
        REVIEW_FINAL_VERDICT=""

        while [[ $review_round -lt $MAX_REVIEW_ROUNDS ]]; do
          review_round=$((review_round + 1))
          TASK_REVIEW_ROUNDS=$review_round
          log "Review round ${review_round}/${MAX_REVIEW_ROUNDS}..."

          run_review_agent "$TASK_CONTENT" "$REVIEW_DIFF" "$LOG_DIR/${TASK_ID}-${TS}-r${review_round}"

          log "Review verdict: ${REVIEW_VERDICT}"

          if [[ "$REVIEW_VERDICT" == "PASS" ]]; then
            ok "Review PASS"
            REVIEW_FINAL_VERDICT="PASS"
            break
          elif [[ "$REVIEW_VERDICT" == "WARN" ]]; then
            warn "Review WARN -- noted, continuing"
            REVIEW_FINAL_VERDICT="WARN"
            break
          elif [[ "$REVIEW_VERDICT" == "FAIL" ]]; then
            if [[ $review_round -ge $MAX_REVIEW_ROUNDS ]]; then
              err "Review FAIL -- max rounds ($MAX_REVIEW_ROUNDS) reached"
              REVIEW_FINAL_VERDICT="FAIL"
              break
            fi

            warn "Review FAIL -- spawning Fix Agent (round $review_round)..."
            REVIEW_FIX_LOG="$LOG_DIR/${TASK_ID}-review-fix-r${review_round}-${TS}.json"
            REVIEW_FIX_PROMPT=$(build_review_fix_prompt "$TASK_ID" "$TASK_TITLE" "$TASK_CONTENT" "$REVIEW_OUTPUT")

            set +e
            timeout "$TASK_TIMEOUT" claude -p "$REVIEW_FIX_PROMPT" \
              -w \
              --model "$MODEL" \
              --dangerously-skip-permissions \
              --max-turns "$MAX_TURNS" \
              --max-budget-usd "$BUDGET_PER_TASK" \
              --output-format json \
              > "$REVIEW_FIX_LOG" 2>"${REVIEW_FIX_LOG%.json}.stderr"
            REVIEW_FIX_EXIT=$?
            set -e

            if [[ $REVIEW_FIX_EXIT -ne 0 ]]; then
              err "Review Fix Agent failed (exit=$REVIEW_FIX_EXIT)"
              REVIEW_FINAL_VERDICT="FAIL"
              break
            fi

            ok "Review Fix Agent done, re-reviewing..."
            GIT_HEAD_AFTER=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")
            [[ "$GIT_HEAD_AFTER" != "unknown" ]] && COMMIT_HASH="$GIT_HEAD_AFTER"
            REVIEW_DIFF=$(git -C "$REPO_ROOT" diff "$GIT_HEAD_BEFORE".."$GIT_HEAD_AFTER" 2>/dev/null || true)
          fi
        done

        TASK_REVIEW_VERDICT="$REVIEW_FINAL_VERDICT"
      fi

      # Determine final task status based on review
      if [[ "$TASK_REVIEW_VERDICT" == "FAIL" ]]; then
        err "${TASK_ID} Review failed (${TASK_REVIEW_ROUNDS} rounds)"
        failed=$((failed + 1))
        consecutive_failures=$((consecutive_failures + 1))
        add_task_result "$TASK_ID" "$TASK_TITLE" "FAIL" "$TASK_DURATION" "$TASK_COST" "$LINES_CHANGED" "$COMMIT_HASH" "review-failed" "$TASK_REVIEW_VERDICT" "$TASK_REVIEW_ROUNDS" "$TASK_PHASE"
        echo "review-failed:$(date -Iseconds):task=$TASK_ID" > "$STATE_FILE"
        LAST_COMPLETED_ID="$TASK_ID"

        if [[ "$consecutive_failures" -lt "$MAX_FAILURES" ]]; then
          warn "Consecutive failures $consecutive_failures/$MAX_FAILURES, continuing"
          warn "Resume from this task: bash scripts/auto-plan-runner.sh $PLAN_NAME --start-from $TASK_ID"
        fi
      else
        [[ "$TASK_REVIEW_VERDICT" == "WARN" ]] && WARN_MSG="${WARN_MSG:+${WARN_MSG},}review-warn"
        completed=$((completed + 1))
        consecutive_failures=0
        add_task_result "$TASK_ID" "$TASK_TITLE" "PASS" "$TASK_DURATION" "$TASK_COST" "$LINES_CHANGED" "$COMMIT_HASH" "$WARN_MSG" "$TASK_REVIEW_VERDICT" "$TASK_REVIEW_ROUNDS" "$TASK_PHASE"
        LAST_COMPLETED_ID="$TASK_ID"
        echo "completed:$(date -Iseconds):task=$TASK_ID:n=$completed" > "$STATE_FILE"
      fi
    else
      err "${TASK_ID} verification failed"
      failed=$((failed + 1))
      consecutive_failures=$((consecutive_failures + 1))
      add_task_result "$TASK_ID" "$TASK_TITLE" "FAIL" "$TASK_DURATION" "$TASK_COST" "$LINES_CHANGED" "$COMMIT_HASH" "verify-failed" "" "0" "$TASK_PHASE"
      echo "verify-failed:$(date -Iseconds):task=$TASK_ID" > "$STATE_FILE"
      LAST_COMPLETED_ID="$TASK_ID"

      if [[ "$consecutive_failures" -lt "$MAX_FAILURES" ]]; then
        warn "Consecutive failures $consecutive_failures/$MAX_FAILURES, continuing"
        warn "Resume from this task: bash scripts/auto-plan-runner.sh $PLAN_NAME --start-from $TASK_ID"
      fi
    fi
  else
    err "${TASK_ID} failed (exit=$EXIT_CODE, ${TASK_DURATION_MIN}m)"
    [[ -f "$LOG_DIR/${TASK_ID}-error.md" ]] && err "Details: $LOG_DIR/${TASK_ID}-error.md"
    err "Log: $TASK_LOG_FILE"
    failed=$((failed + 1))
    consecutive_failures=$((consecutive_failures + 1))
    add_task_result "$TASK_ID" "$TASK_TITLE" "FAIL" "$TASK_DURATION" "$TASK_COST" "$LINES_CHANGED" "$COMMIT_HASH" "" "" "0" "$TASK_PHASE"
    echo "failed:$(date -Iseconds):task=$TASK_ID" > "$STATE_FILE"
    LAST_COMPLETED_ID="$TASK_ID"

    if [[ "$consecutive_failures" -lt "$MAX_FAILURES" ]]; then
      warn "Consecutive failures $consecutive_failures/$MAX_FAILURES, continuing"
      warn "Resume from this task: bash scripts/auto-plan-runner.sh $PLAN_NAME --start-from $TASK_ID"
    fi
  fi

  START_FROM=""
  [[ "$PAUSE_BETWEEN" -gt 0 ]] && { log "Pausing ${PAUSE_BETWEEN}s..."; sleep "$PAUSE_BETWEEN"; }
done

echo ""
echo -e "${B}===================================================${N}"
ok "Complete: $completed | Failed: $failed | Iterations: $iteration"
[[ "$failed" -eq 0 && "$completed" -gt 0 ]] && rm -f "$STATE_FILE"
echo -e "${B}===================================================${N}"

if [[ ${#TASK_RESULTS[@]} -gt 0 ]]; then
  generate_summary
  echo ""
  echo -e "Run ${B}/vibe review ${PLAN_NAME}${N} for improvement suggestions"
fi

echo ""

#!/usr/bin/env bash
#
# deploy.sh -- Build, test, and deploy (simplified, project-agnostic)
#
# Handles:
#   - Uncommitted change detection (safety gate)
#   - Change scope detection (full / client-only / none)
#   - Database backup
#   - Dependency install
#   - Client + server build
#   - Adaptive test level (unit / integration / full / skip)
#   - Service restart with zero-downtime cluster reload
#   - Deployment verification
#
# Customize the service restart section for your environment.
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PORT="${APP_PORT:-3000}"
MGMT_PORT="${MGMT_PORT:-3099}"
MGMT_URL="http://127.0.0.1:${MGMT_PORT}"
DEPLOY_HASH_FILE="server/data/.deploy-commit"
LOG_FILE="${SERVER_LOG:-$PROJECT_DIR/server/data/server.log}"

cd "$PROJECT_DIR"
source "$PROJECT_DIR/scripts/deploy-patterns.sh"

# -- Silent runner helper -----------------------------------------------
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

echo ""
echo "=========================================="
echo "  Deploy"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

# -- Step 0: Check for uncommitted source changes ----------------------
if ! git diff --quiet -- client/src/ server/src/ 2>/dev/null || ! git diff --cached --quiet -- client/src/ server/src/ 2>/dev/null; then
  echo ""
  echo "  WARNING: Uncommitted source changes detected:"
  git diff --name-only -- client/src/ server/src/ 2>/dev/null | sed 's/^/    [unstaged] /'
  git diff --cached --name-only -- client/src/ server/src/ 2>/dev/null | sed 's/^/    [staged] /'
  echo ""
  echo "  Risk: A rollback (git reset --hard) would lose these changes!"
  echo "  Recommendation: commit first, then deploy."
  echo "  Skip check: SKIP_COMMIT_CHECK=1 bash deploy.sh"
  if [ "${SKIP_COMMIT_CHECK:-}" != "1" ]; then
    exit 1
  fi
  echo "  SKIP_COMMIT_CHECK=1, continuing..."
fi

# -- Change scope detection --------------------------------------------
CURRENT_COMMIT=$(git rev-parse HEAD)

if [ -z "${DEPLOY_SCOPE:-}" ]; then
  LAST_DEPLOY=$(cat "$DEPLOY_HASH_FILE" 2>/dev/null || echo "")

  if [ -n "$LAST_DEPLOY" ] && git cat-file -e "$LAST_DEPLOY" 2>/dev/null; then
    CHANGED_FILES=$(git diff --name-only "$LAST_DEPLOY".."$CURRENT_COMMIT" 2>/dev/null || echo "")
  else
    CHANGED_FILES=$(git diff --name-only HEAD~1 2>/dev/null || echo "")
  fi

  if [ -z "$CHANGED_FILES" ]; then
    DEPLOY_SCOPE="full"
  else
    DEPLOY_SCOPE=$(classify_changes "$CHANGED_FILES")
  fi
fi

case "$DEPLOY_SCOPE" in
  full|client|none) ;;
  *) echo "  Error: invalid DEPLOY_SCOPE=$DEPLOY_SCOPE (allowed: full, client, none)"; exit 1 ;;
esac

# No runtime impact: record hash and exit
if [ "$DEPLOY_SCOPE" = "none" ]; then
  echo ""
  echo "  Change scope: no runtime impact -- skipping build and deploy"
  echo "$CURRENT_COMMIT" > "$DEPLOY_HASH_FILE"
  echo ""
  echo "=========================================="
  echo "  No deploy needed (docs/config changes only)"
  echo "=========================================="
  # exit 2 = success but no actual deploy (vs exit 0 = deployed)
  exit 2
fi

echo ""
if [ "$DEPLOY_SCOPE" = "client" ]; then
  echo "  Change scope: client only -- skipping server build and restart"
else
  echo "  Change scope: full -- includes server build and restart"
fi

# -- Step 1: Backup database -------------------------------------------
echo ""
echo "[1/6] Backup database..."
DB_FILE="${DB_PATH:-server/data/app.db}"
if [ -f "$DB_FILE" ]; then
  BACKUP_DIR="server/data/backups"
  mkdir -p "$BACKUP_DIR"
  BACKUP_FILE="$BACKUP_DIR/$(basename "$DB_FILE" .db)_$(date '+%Y%m%d_%H%M%S').db"
  cp "$DB_FILE" "$BACKUP_FILE"
  echo "  Backed up: $BACKUP_FILE"

  BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/*.db 2>/dev/null | wc -l)
  if [ "$BACKUP_COUNT" -gt 10 ]; then
    ls -1t "$BACKUP_DIR"/*.db | tail -n +11 | xargs rm -f
    echo "  Cleaned old backups, keeping latest 10"
  fi
else
  echo "  No database file found at $DB_FILE, skipping backup"
fi

# -- Step 2: Install dependencies --------------------------------------
echo ""
echo "[2/6] Install dependencies..."
npm install --ignore-scripts 2>&1 | tail -1

# -- Step 3: Build client ----------------------------------------------
echo ""
echo "[3/6] Build client..."
run_silent "Build client" npm run build -w client

# -- Step 3.1: Build server (if full scope) ----------------------------
echo ""
if [ "$DEPLOY_SCOPE" = "client" ]; then
  echo "[3.1/6] Build server... skipped (client-only changes)"
else
  echo "[3.1/6] Build server..."
  run_silent "Build server" npm run build -w server
fi

# -- Step 4: Run tests -------------------------------------------------
echo ""
echo "[4/6] Run tests..."

TEST_LEVEL="${TEST_LEVEL:-auto}"

if [ "$TEST_LEVEL" = "auto" ]; then
  CHANGED=$(git diff --name-only HEAD 2>/dev/null || echo "")
  if [ -z "$CHANGED" ]; then
    CHANGED=$(git diff --name-only HEAD~1 2>/dev/null || echo "")
  fi

  if echo "$CHANGED" | grep -qE "^server/src/auth/"; then
    TEST_LEVEL="full"
  elif echo "$CHANGED" | grep -E "^server/src/" | grep -qvE "\.test\.ts$"; then
    TEST_LEVEL="integration"
  elif echo "$CHANGED" | grep -qE "^(client/src/|server/src/)"; then
    TEST_LEVEL="unit"
  else
    TEST_LEVEL="skip"
  fi
fi

case "$TEST_LEVEL" in
  unit)
    echo "  Test level: unit"
    run_silent "Unit tests" npm run test:unit
    ;;
  integration)
    echo "  Test level: unit + integration"
    run_silent "Unit tests" npm run test:unit
    run_silent "Integration tests" npm run test:integration
    ;;
  full)
    echo "  Test level: full (unit + integration + E2E)"
    run_silent "Unit tests" npm run test:unit
    run_silent "Integration tests" npm run test:integration
    run_silent "E2E tests" npm run test:e2e
    ;;
  skip)
    echo "  Test level: skip (TEST_LEVEL=skip)"
    ;;
  *)
    echo "  Unknown test level: $TEST_LEVEL, falling back to unit"
    run_silent "Unit tests" npm run test:unit
    ;;
esac

if [ "$TEST_LEVEL" != "skip" ]; then
  echo "  Tests passed"
fi

# -- Step 5: Restart service -------------------------------------------
echo ""
if [ "$DEPLOY_SCOPE" = "client" ]; then
  echo "[5/6] Restart service... skipped (client-only, static files updated)"
else
  echo "[5/6] Restart service..."

  # Check if cluster management API is responding
  if curl -s --connect-timeout 2 "${MGMT_URL}/status" > /dev/null 2>&1; then

    # Check if cluster.js (master code) has changed
    CLUSTER_HASH_FILE="server/data/.cluster-hash"
    NEW_CLUSTER_HASH=$(sha256sum server/dist/cluster.js 2>/dev/null | awk '{print $1}')
    OLD_CLUSTER_HASH=$(cat "$CLUSTER_HASH_FILE" 2>/dev/null || echo "")

    if [ -n "$NEW_CLUSTER_HASH" ] && [ "$NEW_CLUSTER_HASH" != "$OLD_CLUSTER_HASH" ]; then
      # cluster.js changed: full restart required
      echo "  cluster.js changed, full master restart required"
      echo "  Requesting graceful shutdown..."

      SHUTDOWN_RESP=$(curl -s --connect-timeout 10 -X POST "${MGMT_URL}/shutdown" 2>&1)
      echo "  Shutdown response: $SHUTDOWN_RESP"

      WAIT_SECS=310
      echo "  Waiting for master to exit (up to ${WAIT_SECS}s)..."
      for i in $(seq 1 $WAIT_SECS); do
        if ! curl -s --connect-timeout 1 "${MGMT_URL}/status" > /dev/null 2>&1; then
          echo "  Master exited (${i}s)"
          break
        fi
        if [ $((i % 30)) -eq 0 ]; then
          echo "  Still waiting... (${i}s/${WAIT_SECS}s)"
        fi
        sleep 1
      done

      sleep 2
      if curl -s --connect-timeout 1 "${MGMT_URL}/status" > /dev/null 2>&1; then
        echo "  Warning: master still running"
        # Platform-specific force-kill logic here:
        # Windows: taskkill //PID ... //F //T
        # Unix: kill -9 <pid>
        echo "  ERROR: Could not terminate old master, deploy aborted"
        exit 1
      fi

      echo "  Starting new Cluster..."
      echo "" >> "$LOG_FILE"
      echo "=== Full restart (cluster.js changed) $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"
      nohup node server/dist/cluster.js >> "$LOG_FILE" 2>&1 &
      disown
      sleep 5

    else
      # Zero-downtime reload (master code unchanged)
      echo "  Cluster management port detected, performing zero-downtime reload..."
      RELOAD_RESP=$(curl -s --connect-timeout 10 -X POST "${MGMT_URL}/reload" 2>&1)
      RELOAD_SUCCESS=$(echo "$RELOAD_RESP" | grep -o '"success":true' || true)

      if [ -n "$RELOAD_SUCCESS" ]; then
        echo "  Zero-downtime reload successful: $RELOAD_RESP"
      else
        echo "  Reload failed: $RELOAD_RESP"
        echo "  Falling back to full restart..."
        echo "  Starting new Cluster..."
        echo "" >> "$LOG_FILE"
        echo "=== Reload fallback restart $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"
        nohup node server/dist/cluster.js >> "$LOG_FILE" 2>&1 &
        disown
        sleep 5
      fi
    fi
  else
    # No cluster management port -- start fresh
    echo "  No cluster management port detected, starting fresh..."
    echo "  Starting Cluster..."
    echo "" >> "$LOG_FILE"
    echo "=== Deploy restart $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"
    nohup node server/dist/cluster.js >> "$LOG_FILE" 2>&1 &
    disown
    sleep 5
  fi
fi

# -- Step 6: Verify deployment -----------------------------------------
echo ""
echo "[6/6] Verify deployment..."

if [ "$DEPLOY_SCOPE" = "client" ]; then
  echo "  Client assets updated (static files served by running server)"
else
  MAX_WAIT=30
  VERIFIED=""
  echo "  Waiting for service to be ready..."
  for i in $(seq 1 $MAX_WAIT); do
    if curl -s --connect-timeout 2 "http://127.0.0.1:${PORT}/" > /dev/null 2>&1; then
      echo "  Service ready (${i}s)"
      VERIFIED=1
      break
    fi
    sleep 1
  done

  if [ "${VERIFIED}" != "1" ]; then
    echo ""
    echo "=========================================="
    echo "  Deploy FAILED! Service not ready within ${MAX_WAIT}s. Check logs:"
    echo "=========================================="
    tail -20 "$LOG_FILE"
    exit 1
  fi

  if ! curl -s --connect-timeout 5 "${MGMT_URL}/status" > /dev/null 2>&1; then
    echo "  Warning: Cluster management port ${MGMT_PORT} not responding (may be in direct mode)"
  else
    echo "  Cluster management port OK"
  fi
fi

# Record the deployed commit hash
echo "$(git rev-parse HEAD)" > "$DEPLOY_HASH_FILE"

echo ""
echo "=========================================="
if [ "$DEPLOY_SCOPE" = "client" ]; then
  echo "  Deploy successful! (client only, service not restarted)"
else
  echo "  Deploy successful!"
fi
echo "  Port: $PORT"
echo "  Log:  $LOG_FILE"
echo "=========================================="

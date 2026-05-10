#!/usr/bin/env bash
# cleanup_daemon.sh — Auto-destroy expired environments every 60 seconds.
# Run with: nohup bash platform/cleanup_daemon.sh &
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

[[ -f "$ROOT_DIR/.env" ]] && source "$ROOT_DIR/.env"

ENVS_DIR="$ROOT_DIR/envs"
LOGS_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOGS_DIR/cleanup.log"
INTERVAL="${CLEANUP_INTERVAL:-60}"

mkdir -p "$LOGS_DIR"

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

log "============================================"
log "Cleanup daemon started (PID: $$, interval: ${INTERVAL}s)"
log "============================================"

# Write own PID so make down can stop us
echo "$$" > "$ROOT_DIR/logs/cleanup_daemon.pid"

while true; do
  NOW=$(date +%s)

  if [[ -d "$ENVS_DIR" ]]; then
    for STATE_FILE in "$ENVS_DIR"/*.json; do
      [[ -e "$STATE_FILE" ]] || continue

      ENV_ID=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['id'])" 2>/dev/null || true)
      EXPIRES_AT=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['expires_at'])" 2>/dev/null || true)
      STATUS=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('status','unknown'))" 2>/dev/null || true)

      [[ -z "$ENV_ID" || -z "$EXPIRES_AT" ]] && continue

      REMAINING=$((EXPIRES_AT - NOW))

      if (( NOW >= EXPIRES_AT )); then
        log "⏰  TTL expired for $ENV_ID (overdue by $((NOW - EXPIRES_AT))s) — destroying..."
        if bash "$SCRIPT_DIR/destroy_env.sh" "$ENV_ID" >> "$LOG_FILE" 2>&1; then
          log "✅  $ENV_ID destroyed successfully."
        else
          log "❌  Failed to destroy $ENV_ID — will retry next cycle."
        fi
      else
        log "   $ENV_ID → status=$STATUS, expires in ${REMAINING}s"
      fi
    done
  fi

  log "--- Sleeping ${INTERVAL}s ---"
  sleep "$INTERVAL"
done

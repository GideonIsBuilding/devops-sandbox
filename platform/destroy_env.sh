#!/usr/bin/env bash
# destroy_env.sh — Tear down a sandbox environment completely
# Usage: ./destroy_env.sh <env_id>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

[[ -f "$ROOT_DIR/.env" ]] && source "$ROOT_DIR/.env"

ENV_ID="${1:?Usage: destroy_env.sh <env_id>}"
NGINX_CONTAINER="${NGINX_CONTAINER:-sandbox-nginx}"
ENVS_DIR="$ROOT_DIR/envs"
NGINX_CONF_DIR="$ROOT_DIR/nginx/conf.d"
LOGS_DIR="$ROOT_DIR/logs"
ARCHIVE_DIR="$LOGS_DIR/archived"

STATE_FILE="$ENVS_DIR/${ENV_ID}.json"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "❌  State file not found for: $ENV_ID" >&2
  exit 1
fi

echo "🗑   Destroying environment: $ENV_ID"

# ── Read state ────────────────────────────────────────────────────────────────
CONTAINER_NAME=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d['container_name'])" 2>/dev/null || echo "sandbox-app-${ENV_ID}")
ENV_NETWORK=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('env_network','sandbox-net-${ENV_ID}'))" 2>/dev/null || echo "sandbox-net-${ENV_ID}")

# ── Kill log shipper ──────────────────────────────────────────────────────────
PID_FILE="$LOGS_DIR/$ENV_ID/log_shipper.pid"
if [[ -f "$PID_FILE" ]]; then
  LOG_PID=$(cat "$PID_FILE")
  if kill -0 "$LOG_PID" 2>/dev/null; then
    kill "$LOG_PID" && echo "   Log shipper (PID $LOG_PID) stopped ✓"
  fi
  rm -f "$PID_FILE"
fi

# ── Stop and remove ALL containers with sandbox.env label ────────────────────
echo "   Stopping containers labeled sandbox.env=$ENV_ID ..."
CONTAINERS=$(docker ps -a --filter "label=sandbox.env=$ENV_ID" --format "{{.ID}}" 2>/dev/null || true)
if [[ -n "$CONTAINERS" ]]; then
  echo "$CONTAINERS" | xargs -r docker rm -f
  echo "   Containers removed ✓"
else
  echo "   No containers found for $ENV_ID"
fi

# ── Remove per-env Docker network ─────────────────────────────────────────────
if docker network inspect "$ENV_NETWORK" &>/dev/null; then
  docker network rm "$ENV_NETWORK" 2>/dev/null || true
  echo "   Network $ENV_NETWORK removed ✓"
fi

# ── Remove nginx config and reload ────────────────────────────────────────────
NGINX_CONF="$NGINX_CONF_DIR/${ENV_ID}.conf"
if [[ -f "$NGINX_CONF" ]]; then
  rm -f "$NGINX_CONF"
  echo "   Nginx config removed ✓"
fi

if docker inspect "$NGINX_CONTAINER" &>/dev/null; then
  docker exec "$NGINX_CONTAINER" nginx -s reload
  echo "   Nginx reloaded ✓"
fi

# ── Archive logs ─────────────────────────────────────────────────────────────
ENV_LOG_DIR="$LOGS_DIR/$ENV_ID"
if [[ -d "$ENV_LOG_DIR" ]]; then
  mkdir -p "$ARCHIVE_DIR"
  ARCHIVE_NAME="${ENV_ID}-$(date +%Y%m%d-%H%M%S)"
  mv "$ENV_LOG_DIR" "$ARCHIVE_DIR/$ARCHIVE_NAME"
  echo "   Logs archived to logs/archived/$ARCHIVE_NAME ✓"
fi

# ── Delete state file ─────────────────────────────────────────────────────────
rm -f "$STATE_FILE"
echo "   State file deleted ✓"

echo ""
echo "✅  Environment $ENV_ID destroyed."

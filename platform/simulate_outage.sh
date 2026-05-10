#!/usr/bin/env bash
# simulate_outage.sh — Inject failures into a sandbox environment
# Usage: ./simulate_outage.sh --env <env_id> --mode <crash|pause|network|recover|stress>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

[[ -f "$ROOT_DIR/.env" ]] && source "$ROOT_DIR/.env"

ENVS_DIR="$ROOT_DIR/envs"

# ── Parse flags ───────────────────────────────────────────────────────────────
ENV_ID=""
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)  ENV_ID="$2";  shift 2 ;;
    --mode) MODE="$2";    shift 2 ;;
    *)      echo "Unknown argument: $1"; exit 1 ;;
  esac
done

[[ -z "$ENV_ID" ]] && { echo "❌  --env <env_id> is required"; exit 1; }
[[ -z "$MODE"   ]] && { echo "❌  --mode <crash|pause|network|recover|stress> is required"; exit 1; }

STATE_FILE="$ENVS_DIR/${ENV_ID}.json"
[[ -f "$STATE_FILE" ]] || { echo "❌  Unknown environment: $ENV_ID"; exit 1; }

CONTAINER_NAME=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['container_name'])")
ENV_NETWORK=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('env_network','sandbox-net-${ENV_ID}'))")
PLATFORM_NETWORK="${PLATFORM_NETWORK:-sandbox-platform}"

# ── Safety guard — never touch infrastructure containers ─────────────────────
PROTECTED_PATTERNS=("sandbox-nginx" "sandbox-api" "sandbox-cleanup" "sandbox-monitor")

check_protected() {
  local target="$1"
  for pattern in "${PROTECTED_PATTERNS[@]}"; do
    if [[ "$target" == *"$pattern"* ]]; then
      echo "🛡️  GUARD: Refusing to simulate outage on protected container: $target"
      exit 1
    fi
  done
  # Also refuse if container doesn't have the sandbox.managed label
  local managed
  managed=$(docker inspect "$target" --format '{{index .Config.Labels "sandbox.managed"}}' 2>/dev/null || echo "")
  if [[ "$managed" != "true" ]]; then
    echo "🛡️  GUARD: Container $target is not a managed sandbox environment. Aborting."
    exit 1
  fi
}

check_protected "$CONTAINER_NAME"

echo "⚡  Simulating [$MODE] on environment $ENV_ID (container: $CONTAINER_NAME)"

update_status() {
  local new_status="$1"
  python3 - <<PYEOF
import json, os
f = '$STATE_FILE'
tmp = f + '.tmp'
with open(f) as fh:
    d = json.load(fh)
d['status'] = '$new_status'
with open(tmp, 'w') as fh:
    json.dump(d, fh, indent=2)
os.replace(tmp, f)
PYEOF
}

case "$MODE" in
  crash)
    echo "   Sending SIGKILL to $CONTAINER_NAME ..."
    docker kill "$CONTAINER_NAME"
    update_status "crashed"
    echo "   💀 Container killed. Health monitor should detect within 90s."
    ;;

  pause)
    echo "   Pausing $CONTAINER_NAME ..."
    docker pause "$CONTAINER_NAME"
    update_status "paused"
    echo "   ⏸  Container paused. Recover with: --mode recover"
    ;;

  network)
    echo "   Disconnecting $CONTAINER_NAME from platform network ..."
    docker network disconnect "$PLATFORM_NETWORK" "$CONTAINER_NAME"
    update_status "network-isolated"
    echo "   🔌 Network disconnected. Nginx will start failing for this env."
    ;;

  stress)
    # Optional: requires stress-ng inside the container
    echo "   Attempting CPU stress on $CONTAINER_NAME ..."
    if docker exec "$CONTAINER_NAME" which stress-ng &>/dev/null; then
      docker exec -d "$CONTAINER_NAME" stress-ng --cpu 2 --timeout 60s
      update_status "stressed"
      echo "   🔥 CPU stress running for 60s."
    else
      echo "   ⚠  stress-ng not found in container. Installing and running..."
      docker exec "$CONTAINER_NAME" sh -c \
        "apt-get update -qq && apt-get install -y -qq stress-ng && stress-ng --cpu 2 --timeout 60s &" 2>/dev/null \
        || echo "   ❌  Could not install stress-ng. Skipping stress mode."
    fi
    ;;

  recover)
    echo "   Recovering $CONTAINER_NAME ..."

    # Check current Docker state
    RUNNING=$(docker inspect "$CONTAINER_NAME" --format '{{.State.Running}}' 2>/dev/null || echo "false")
    PAUSED=$(docker inspect "$CONTAINER_NAME" --format '{{.State.Paused}}' 2>/dev/null || echo "false")

    if [[ "$PAUSED" == "true" ]]; then
      docker unpause "$CONTAINER_NAME"
      echo "   ▶  Container unpaused ✓"
    fi

    if [[ "$RUNNING" == "false" ]]; then
      docker start "$CONTAINER_NAME"
      echo "   ▶  Container restarted ✓"
    fi

    # Re-attach to platform network if disconnected
    if ! docker network inspect "$PLATFORM_NETWORK" \
        --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null \
        | grep -q "$CONTAINER_NAME"; then
      docker network connect "$PLATFORM_NETWORK" "$CONTAINER_NAME"
      echo "   🔗 Reconnected to platform network ✓"
    fi

    update_status "running"
    echo "   ✅  Environment $ENV_ID recovered."
    ;;

  *)
    echo "❌  Unknown mode: $MODE. Valid: crash | pause | network | recover | stress"
    exit 1
    ;;
esac

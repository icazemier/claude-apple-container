#!/bin/bash
# shell.sh — Open an interactive shell in the Claude Dev container
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ─── Load .env ────────────────────────────────────────────────────────────────

if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a; source .env; set +a
fi

CONTAINER_NAME=${CONTAINER_NAME:-claude-dev}

# ─── Ensure API is responsive ─────────────────────────────────────────────────

api_healthy() {
  ! container image ls 2>&1 | grep -qi "unavailable\|transport.*inactive"
}

if ! api_healthy; then
  echo "Container system unresponsive — restarting..."
  container system stop &>/dev/null || true
  container system start --enable-kernel-install &>/dev/null
  RETRIES=0
  while ! api_healthy && [ $RETRIES -lt 15 ]; do sleep 1; RETRIES=$((RETRIES + 1)); done
fi

# ─── Check container is running ───────────────────────────────────────────────

STATE=$(container inspect "$CONTAINER_NAME" 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")

if [ "$STATE" != "running" ]; then
  echo "Container is not running. Start it with: ./up.sh"
  exit 1
fi

# ─── Exec into container ─────────────────────────────────────────────────────

exec container exec -it -u claude -w /home/claude "$CONTAINER_NAME" bash -l

#!/bin/bash
# stop.sh — Stop the Claude Dev container
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ─── Load .env ────────────────────────────────────────────────────────────────

if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a; source .env; set +a
fi

CONTAINER_NAME=${CONTAINER_NAME:-claude-dev}

# ─── Stop container ──────────────────────────────────────────────────────────

STATE=$(container inspect "$CONTAINER_NAME" 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")

if [ "$STATE" != "running" ]; then
  echo "Container is not running ($CONTAINER_NAME)"
  exit 0
fi

echo "==> Stopping container $CONTAINER_NAME..."
if ! container stop "$CONTAINER_NAME" 2>/dev/null; then
  echo "==> Graceful stop failed, force killing..."
  container kill "$CONTAINER_NAME" 2>/dev/null || true
fi
echo "Container stopped."

#!/bin/bash
# destroy.sh — Remove the Claude Dev container and associated resources
# The named volume (claude-home) is kept by default to preserve personal config.
# Pass --all to also remove the volume and cached images.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ─── Load .env ────────────────────────────────────────────────────────────────

if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a; source .env; set +a
fi

CONTAINER_NAME=${CONTAINER_NAME:-claude-dev}
IMAGE_NAME="claude-apple-container:latest"
VOLUME_NAME="claude-home"

ALL=false
for arg in "$@"; do
  [ "$arg" = "--all" ] && ALL=true
done

# ─── Stop container if running ────────────────────────────────────────────────

STATE=$(container inspect "$CONTAINER_NAME" 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")

if [ "$STATE" = "running" ]; then
  echo "==> Container is running — stopping first..."
  if ! container stop "$CONTAINER_NAME" 2>/dev/null; then
    echo "==> Graceful stop failed, force killing..."
    container kill "$CONTAINER_NAME" 2>/dev/null || true
  fi
fi

# ─── Remove container ────────────────────────────────────────────────────────

if [ -n "$STATE" ]; then
  echo "==> Removing container $CONTAINER_NAME..."
  container rm -f "$CONTAINER_NAME" 2>/dev/null || true
fi

# ─── Optionally remove volume and image ───────────────────────────────────────

if $ALL; then
  echo "==> Removing volume $VOLUME_NAME..."
  container volume rm "$VOLUME_NAME" 2>/dev/null || true

  echo "==> Removing image $IMAGE_NAME..."
  container image rm "$IMAGE_NAME" 2>/dev/null || true

  echo ""
  echo "Done. Everything removed. Next ./up.sh will rebuild from scratch."
else
  echo ""
  echo "Done. Container removed (volume and image kept for fast rebuild)."
  echo "  /home/claude data is preserved in volume: $VOLUME_NAME"
  echo ""
  echo "  Rebuild:       ./up.sh"
  echo "  Remove all:    $0 --all"
fi

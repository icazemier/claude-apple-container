#!/bin/bash
# up.sh — Build and start the Claude Dev container (Apple Containers)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ─── Output helpers ──────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
TOTAL_STEPS=6
CURRENT_STEP=0

die() { printf "${RED}ERROR:${NC} %s\n" "$*" >&2; exit 1; }

step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  printf "${BOLD}[%d/%d]${NC} %s" "$CURRENT_STEP" "$TOTAL_STEPS" "$1"
}

ok() {
  local extra=""
  [ $# -gt 0 ] && extra=" ${CYAN}($1)${NC}"
  printf " ${GREEN}✓${NC}%b\n" "$extra"
}

fail() {
  printf " ${RED}✗${NC}\n"
  [ $# -gt 0 ] && printf "      ${RED}%s${NC}\n" "$1"
}

# ─── Load .env ────────────────────────────────────────────────────────────────

if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a; source .env; set +a
fi

CONTAINER_NAME=${CONTAINER_NAME:-claude-dev}
SHARED_FOLDER=${SHARED_FOLDER:-}
FORWARDED_PORTS=${FORWARDED_PORTS:-}
VM_MEMORY=${VM_MEMORY:-8G}
VM_CPUS=${VM_CPUS:-4}

IMAGE_NAME="claude-apple-container:latest"
VOLUME_NAME="claude-home"

# ─── Step 1: Validate prerequisites ──────────────────────────────────────────

step "Checking prerequisites..."

# Apple Silicon check
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
  fail
  die "Apple Silicon required. Detected: $ARCH"
fi

# macOS check
OS=$(uname -s)
if [ "$OS" != "Darwin" ]; then
  fail
  die "macOS required. Detected: $OS"
fi

# container CLI check
if ! command -v container &>/dev/null; then
  fail
  die "Apple container CLI not found. Install from: https://github.com/apple/container/releases"
fi

# Validate .env variables
if [ -n "$SHARED_FOLDER" ] && [ ! -d "$SHARED_FOLDER" ]; then
  fail
  die "SHARED_FOLDER does not exist: $SHARED_FOLDER"
fi

if [ -n "$FORWARDED_PORTS" ]; then
  for port in ${FORWARDED_PORTS//,/ }; do
    port="${port// /}"
    [ -z "$port" ] && continue
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
      fail
      die "Invalid port in FORWARDED_PORTS: $port"
    fi
  done
fi

ok

# ─── Ensure container system is running ───────────────────────────────────────

if ! container system info &>/dev/null; then
  step "Starting container system..."
  container system start --enable-kernel-install
  ok
else
  CURRENT_STEP=$((CURRENT_STEP + 1))
fi

# ─── Check if container is already running ────────────────────────────────────

STATE=$(container inspect "$CONTAINER_NAME" 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")

if [ "$STATE" = "running" ]; then
  echo ""
  printf "${GREEN}Container is already running${NC} ($CONTAINER_NAME)\n"
  echo "  Shell:   ./shell.sh"
  echo "  Stop:    ./stop.sh"
  exit 0
fi

# ─── Step 2: Build image (if needed) ─────────────────────────────────────────

# Check if image exists
if ! container image ls 2>/dev/null | grep -q "$IMAGE_NAME"; then
  step "Building container image..."
  echo ""
  container build -t "$IMAGE_NAME" "$SCRIPT_DIR"
  printf "  ${GREEN}✓ Image built${NC}\n"
else
  step "Image exists..."
  ok "skipping build"
fi

# ─── Step 3: Create volume (if needed) ────────────────────────────────────────

if ! container volume ls 2>/dev/null | grep -q "$VOLUME_NAME"; then
  step "Creating persistent volume..."
  container volume create "$VOLUME_NAME"
  ok
else
  step "Volume exists..."
  ok "$VOLUME_NAME"
fi

# ─── Step 4: Start container ─────────────────────────────────────────────────

# If container exists but is stopped, start it
if [ "$STATE" = "stopped" ] || [ "$STATE" = "created" ]; then
  step "Starting existing container..."
  container start "$CONTAINER_NAME"
  ok
else
  # Create and run new container
  step "Starting new container..."

  RUN_ARGS=(
    -d
    --name "$CONTAINER_NAME"
    --ssh
    -m "$VM_MEMORY"
    -c "$VM_CPUS"
    -v "${VOLUME_NAME}:/home/claude"
  )

  # Shared folder
  if [ -n "$SHARED_FOLDER" ]; then
    RUN_ARGS+=(-v "${SHARED_FOLDER}:/home/claude/shared")
  fi

  # Port forwarding
  if [ -n "$FORWARDED_PORTS" ]; then
    for port in ${FORWARDED_PORTS//,/ }; do
      port="${port// /}"
      [ -n "$port" ] && RUN_ARGS+=(-p "127.0.0.1:${port}:${port}")
    done
  fi

  RUN_ARGS+=("$IMAGE_NAME")

  container run "${RUN_ARGS[@]}"
  ok
fi

# ─── Install extra packages from packages.txt ────────────────────────────────

if [ -f "$SCRIPT_DIR/packages.txt" ]; then
  PKGS=$(grep -v '^\s*#' "$SCRIPT_DIR/packages.txt" | grep -v '^\s*$' | tr '\n' ' ')
  if [ -n "$PKGS" ]; then
    step "Installing extra packages..."
    container exec -u root "$CONTAINER_NAME" apk add --no-cache $PKGS >/dev/null 2>&1
    ok
  fi
fi

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
printf "  ${BOLD}Shell:${NC}   ./shell.sh\n"
printf "  ${BOLD}Stop:${NC}    ./stop.sh\n"
printf "  ${BOLD}Destroy:${NC} ./destroy.sh\n"
echo ""

#!/bin/bash
# up.sh — Build and start the Claude Dev container (Apple Containers)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ─── Output helpers ──────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
TOTAL_STEPS=11
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
EXTRA_PACKAGES=${EXTRA_PACKAGES:-}
DOTFILES=${DOTFILES:-}
COPY_FOLDERS=${COPY_FOLDERS:-}
SWAP_SIZE=${SWAP_SIZE:-2G}
WATCHDOG_MEM_CRIT_MB=${WATCHDOG_MEM_CRIT_MB:-400}
WATCHDOG_MEM_RESUME_MB=${WATCHDOG_MEM_RESUME_MB:-1200}
WATCHDOG_POLL=${WATCHDOG_POLL:-5}

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

if [ -n "$DOTFILES" ]; then
  for df in ${DOTFILES//,/ }; do
    # Expand ~ manually since it doesn't expand inside quotes
    df="${df/#\~/$HOME}"
    if [ ! -e "$df" ]; then
      fail
      die "DOTFILES entry does not exist: $df"
    fi
  done
fi

if [ -n "$COPY_FOLDERS" ]; then
  for cf in ${COPY_FOLDERS//,/ }; do
    cf="${cf/#\~/$HOME}"
    if [ ! -d "$cf" ]; then
      fail
      die "COPY_FOLDERS entry does not exist or is not a directory: $cf"
    fi
  done
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

# ─── Ensure container system is running and API is responsive ─────────────────

api_healthy() {
  # container CLI returns exit 0 even on transport errors — check stderr
  ! container image ls 2>&1 | grep -qi "unavailable\|transport.*inactive"
}

wait_for_api() {
  local retries=0 consecutive=0
  while [ $consecutive -lt 3 ] && [ $retries -lt 30 ]; do
    if api_healthy; then
      consecutive=$((consecutive + 1))
    else
      consecutive=0
    fi
    sleep 1
    retries=$((retries + 1))
  done
  [ $consecutive -ge 3 ]
}

start_system() {
  container system stop &>/dev/null || true
  sleep 3  # let daemon processes fully exit before restarting
  container system start --enable-kernel-install
  wait_for_api
}

if ! container system status 2>/dev/null | grep -qw "running"; then
  step "Starting container system..."
  if start_system; then
    ok
  else
    fail "API server did not become ready"
    die "Try: container system stop && container system start"
  fi
elif ! api_healthy; then
  step "Restarting container system (stale API)..."
  if start_system; then
    ok
  else
    fail "API server did not become ready after restart"
    die "Try: container system stop && container system start"
  fi
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

MAX_API_ATTEMPTS=3
API_ATTEMPT=0
IMAGE_READY=false

while [ "$IMAGE_READY" = false ] && [ $API_ATTEMPT -lt $MAX_API_ATTEMPTS ]; do
  # Check if image exists — distinguish "not found" from "API broken"
  img_output=$(container image ls 2>&1)
  if echo "$img_output" | grep -qi "unavailable\|transport.*inactive"; then
    API_ATTEMPT=$((API_ATTEMPT + 1))
    if [ $API_ATTEMPT -ge $MAX_API_ATTEMPTS ]; then
      die "Container API did not recover after $MAX_API_ATTEMPTS restart attempts"
    fi
    step "Restarting container system (attempt $API_ATTEMPT/$MAX_API_ATTEMPTS)..."
    if start_system; then ok; else fail; die "Container system did not recover"; fi
    continue
  fi

  if echo "$img_output" | grep -q "${IMAGE_NAME%%:*}"; then
    step "Image exists..."
    ok "skipping build"
    IMAGE_READY=true
    continue
  fi

  # Image genuinely doesn't exist — build it
  step "Building container image..."
  echo ""
  if container build -t "$IMAGE_NAME" "$SCRIPT_DIR"; then
    printf "  ${GREEN}✓ Image built${NC}\n"
    IMAGE_READY=true
  else
    API_ATTEMPT=$((API_ATTEMPT + 1))
    if [ $API_ATTEMPT -ge $MAX_API_ATTEMPTS ]; then
      die "Image build failed after $MAX_API_ATTEMPTS attempts"
    fi
    printf "  ${YELLOW}Build failed — restarting container system (attempt $API_ATTEMPT/$MAX_API_ATTEMPTS)...${NC}\n"
    start_system || die "Container system did not recover"
  fi
done

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

# ─── Timeout helper ──────────────────────────────────────────────────────────

START_TIMEOUT=${START_TIMEOUT:-30}

run_with_timeout() {
  local timeout=$1; shift
  "$@" &
  local pid=$!
  ( sleep "$timeout" && kill "$pid" 2>/dev/null ) &
  local watchdog=$!
  if wait "$pid" 2>/dev/null; then
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
    return 0
  else
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
    return 1
  fi
}

# If container exists but is stopped, try to start it; if it fails
# (e.g. stale mounts from a previous run), destroy and recreate.
if [ "$STATE" = "stopped" ] || [ "$STATE" = "created" ]; then
  step "Starting existing container..."
  if run_with_timeout "$START_TIMEOUT" container start "$CONTAINER_NAME" 2>/dev/null; then
    ok
  else
    fail "stale config — recreating"
    container rm -f "$CONTAINER_NAME" &>/dev/null || true
    CURRENT_STEP=$((CURRENT_STEP - 1))
    STATE=""
  fi
fi

if [ -z "$STATE" ]; then
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

  # Dotfiles — stage into temp dir and mount read-only
  DOTFILES_STAGE=""
  if [ -n "$DOTFILES" ]; then
    DOTFILES_STAGE="$SCRIPT_DIR/.stage-dotfiles"
    rm -rf "$DOTFILES_STAGE"
    mkdir -p "$DOTFILES_STAGE"
    for df in ${DOTFILES//,/ }; do
      df="${df/#\~/$HOME}"
      # Derive the relative path under $HOME (e.g. ~/.ssh → .ssh)
      rel="${df#$HOME/}"
      if [ "$rel" = "$df" ]; then
        # Not under $HOME — use basename
        rel="$(basename "$df")"
      fi
      if [ -d "$df" ]; then
        mkdir -p "$DOTFILES_STAGE/$rel"
        cp -a "$df/." "$DOTFILES_STAGE/$rel/"
      else
        mkdir -p "$DOTFILES_STAGE/$(dirname "$rel")"
        cp -a "$df" "$DOTFILES_STAGE/$rel"
      fi
    done
    RUN_ARGS+=(-v "${DOTFILES_STAGE}:/mnt/dotfiles:ro")
  fi

  # Copy folders — mount source paths directly (read-only)
  if [ -n "$COPY_FOLDERS" ]; then
    idx=0
    for cf in ${COPY_FOLDERS//,/ }; do
      cf="${cf/#\~/$HOME}"
      if [ -d "$cf" ]; then
        RUN_ARGS+=(-v "${cf}:/mnt/copy_folders/${idx}:ro")
        idx=$((idx + 1))
      fi
    done
  fi

  # Watchdog / swap env vars
  RUN_ARGS+=(
    -e "SWAP_SIZE=${SWAP_SIZE}"
    -e "WATCHDOG_MEM_CRIT_MB=${WATCHDOG_MEM_CRIT_MB}"
    -e "WATCHDOG_MEM_RESUME_MB=${WATCHDOG_MEM_RESUME_MB}"
    -e "WATCHDOG_POLL=${WATCHDOG_POLL}"
  )

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

# ─── Restore dotfiles from host ───────────────────────────────────────────────

if [ -n "$DOTFILES" ]; then
  step "Restoring dotfiles..."
  container exec "$CONTAINER_NAME" bash -c '
    if [ -d /mnt/dotfiles ]; then
      cd /mnt/dotfiles
      find . -type f -o -type l | while read -r f; do
        dest="$HOME/$f"
        mkdir -p "$(dirname "$dest")"
        if [ ! -e "$dest" ]; then
          cp -a "$f" "$dest"
        fi
      done
      # Fix SSH key permissions
      if [ -d "$HOME/.ssh" ]; then
        chmod 700 "$HOME/.ssh"
        chmod 600 "$HOME/.ssh/"* 2>/dev/null || true
        chmod 644 "$HOME/.ssh/"*.pub 2>/dev/null || true
        chmod 644 "$HOME/.ssh/known_hosts" 2>/dev/null || true
        chmod 644 "$HOME/.ssh/config" 2>/dev/null || true
      fi
    fi
  ' 2>/dev/null
  ok
else
  CURRENT_STEP=$((CURRENT_STEP + 1))
fi

# ─── Copy project folders from host ──────────────────────────────────────────

if [ -n "$COPY_FOLDERS" ]; then
  step "Copying project folders..."
  # Pass folder names so the VM knows what to name each copy
  COPY_NAMES=""
  for cf in ${COPY_FOLDERS//,/ }; do
    cf="${cf/#\~/$HOME}"
    COPY_NAMES="${COPY_NAMES:+$COPY_NAMES,}$(basename "$cf")"
  done
  container exec "$CONTAINER_NAME" bash -c '
    idx=0
    IFS=, read -ra names <<< "'"$COPY_NAMES"'"
    for name in "${names[@]}"; do
      src="/mnt/copy_folders/$idx"
      dest="$HOME/$name"
      if [ -d "$src" ] && [ ! -d "$dest" ]; then
        echo "    Copying $name..."
        mkdir -p "$dest"
        # Exclude node_modules — handled by nm-local
        tar -cf - --exclude=node_modules -C "$src" . | tar -xf - -C "$dest"
      fi
      idx=$((idx + 1))
    done
  '
  ok
else
  CURRENT_STEP=$((CURRENT_STEP + 1))
fi

# ─── Install extra packages from .env ─────────────────────────────────────────

if [ -n "$EXTRA_PACKAGES" ]; then
  step "Installing extra packages..."
  container exec -u root "$CONTAINER_NAME" apk add --no-cache $EXTRA_PACKAGES >/dev/null 2>&1
  ok
else
  CURRENT_STEP=$((CURRENT_STEP + 1))
fi

# ─── Install MCP servers (globally) ──────────────────────────────────────────

step "Installing MCP servers..."
container exec -u root "$CONTAINER_NAME" sh -c '
  npm ls -g @azure-devops/mcp >/dev/null 2>&1 && npm ls -g @playwright/mcp >/dev/null 2>&1
' 2>/dev/null && ok "already installed" || {
  container exec -u root "$CONTAINER_NAME" npm install -g @azure-devops/mcp @playwright/mcp >/dev/null 2>&1
  ok
}

# ─── Ensure .bashrc sources /etc/profile.d/ (for nm-local, etc.) ─────────────

step "Patching shell config..."
container exec -u claude "$CONTAINER_NAME" bash -c '
  MARKER="# ─── Source image-level profile scripts"
  if ! grep -q "$MARKER" ~/.bashrc 2>/dev/null; then
    sed -i "/^case \\\$- in/i\\
$MARKER (survive volume mounts) ───────────────\\
for f in /etc/profile.d/*.sh; do [ -r \"\\\$f\" ] \\&\\& . \"\\\$f\"; done\\
" ~/.bashrc
  fi
' 2>/dev/null
ok

# ─── Provision MCP servers (user-level, global paths) ───────────────────────
# Reads project-level .mcp.json, strips node_modules/.bin/ prefixes so commands
# resolve to globally-installed binaries, writes to ~/.claude/.mcp.json, then
# removes the project-level file to prevent conflicts (project-level overrides
# user-level for same-named servers, even when the local binary path is broken).

step "Provisioning MCP servers..."
container exec -u claude "$CONTAINER_NAME" bash -c '
  found=$(find $HOME -maxdepth 4 -name ".mcp.json" ! -path "*/.claude/*" -print -quit 2>/dev/null)
  if [ -n "$found" ]; then
    mkdir -p $HOME/.claude
    sed "s|node_modules/\.bin/||g" "$found" > $HOME/.claude/.mcp.json
    find $HOME -maxdepth 4 -name ".mcp.json" ! -path "*/.claude/*" -delete 2>/dev/null || true
  fi
' 2>/dev/null
ok

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
printf "  ${BOLD}Shell:${NC}   ./shell.sh\n"
printf "  ${BOLD}Stop:${NC}    ./stop.sh\n"
printf "  ${BOLD}Destroy:${NC} ./destroy.sh\n"
echo ""

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
STOP_TIMEOUT=${STOP_TIMEOUT:-10}

ALL=false
for arg in "$@"; do
  [ "$arg" = "--all" ] && ALL=true
done

# ─── Helpers ─────────────────────────────────────────────────────────────────

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

kill_vm_process() {
  local name=$1
  local runtime_pid
  runtime_pid=$(pgrep -f "container-runtime-linux start --root.*--uuid ${name}$" || true)
  if [ -z "$runtime_pid" ]; then
    return 1
  fi
  local vm_pids
  vm_pids=$(pgrep -P "$runtime_pid" 2>/dev/null || true)
  if [ -n "$vm_pids" ]; then
    echo "==> Killing VM process(es): $vm_pids"
    kill -9 $vm_pids 2>/dev/null || true
  fi
  echo "==> Killing runtime process: $runtime_pid"
  kill -9 "$runtime_pid" 2>/dev/null || true
  return 0
}

diagnose_container() {
  local name=$1
  echo ""
  echo "─── Diagnostics ───────────────────────────────────────────────"
  local stats_json
  stats_json=$(run_with_timeout 5 container stats "$name" --no-stream --format json 2>/dev/null) || true
  if [ -n "$stats_json" ]; then
    local mem_used mem_limit mem_pct pids
    mem_used=$(echo "$stats_json" | grep -o '"memoryUsageBytes":[0-9]*' | cut -d: -f2)
    mem_limit=$(echo "$stats_json" | grep -o '"memoryLimitBytes":[0-9]*' | cut -d: -f2)
    pids=$(echo "$stats_json" | grep -o '"numProcesses":[0-9]*' | cut -d: -f2)
    if [ -n "$mem_used" ] && [ -n "$mem_limit" ] && [ "$mem_limit" -gt 0 ]; then
      mem_pct=$((mem_used * 100 / mem_limit))
      echo "  Memory: $((mem_used / 1048576)) MiB / $((mem_limit / 1048576)) MiB (${mem_pct}%)"
      [ "$mem_pct" -ge 95 ] && echo "  ⚠ Memory near limit — likely OOM inside VM"
    fi
    [ -n "$pids" ] && echo "  Processes: $pids"
  else
    echo "  Stats: unavailable (VM unresponsive)"
  fi
  local oom_lines
  oom_lines=$(container logs "$name" --boot -n 100 2>/dev/null | grep -i "oom-kill\|Out of memory\|invoked oom-killer" || true)
  if [ -n "$oom_lines" ]; then
    echo "  OOM detected in VM kernel log:"
    echo "$oom_lines" | tail -3 | sed 's/^/    /'
  fi
  local host_pressure
  host_pressure=$(memory_pressure 2>/dev/null | head -1 || true)
  [ -n "$host_pressure" ] && echo "  Host: $host_pressure"
  echo "────────────────────────────────────────────────────────────────"
  echo ""
}

# ─── Ensure API is responsive ─────────────────────────────────────────────────

api_healthy() {
  ! container image ls 2>&1 | grep -qi "unavailable\|transport.*inactive"
}

if ! api_healthy; then
  echo "==> Container system unresponsive — restarting..."
  container system stop &>/dev/null || true
  sleep 3
  container system start --enable-kernel-install &>/dev/null
  RETRIES=0; CONSECUTIVE=0
  while [ $CONSECUTIVE -lt 3 ] && [ $RETRIES -lt 30 ]; do
    if api_healthy; then CONSECUTIVE=$((CONSECUTIVE + 1)); else CONSECUTIVE=0; fi
    sleep 1; RETRIES=$((RETRIES + 1))
  done
fi

# ─── Stop container if running ────────────────────────────────────────────────

STATE=$(container inspect "$CONTAINER_NAME" 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")

if [ -z "$STATE" ]; then
  # API might still be dead or container unknown — check for orphaned VM
  if kill_vm_process "$CONTAINER_NAME"; then
    echo "==> Killed orphaned VM process."
  fi
elif [ "$STATE" = "running" ]; then
  echo "==> Container is running — stopping first..."
  if run_with_timeout "$STOP_TIMEOUT" container stop -t 5 "$CONTAINER_NAME" 2>/dev/null; then
    true
  else
    echo "==> Graceful stop timed out, collecting diagnostics..."
    diagnose_container "$CONTAINER_NAME"
    if run_with_timeout "$STOP_TIMEOUT" container kill "$CONTAINER_NAME" 2>/dev/null; then
      echo "==> Force killed."
    elif kill_vm_process "$CONTAINER_NAME"; then
      echo "==> VM process killed (container was unresponsive)."
      sleep 1
    else
      echo "==> WARNING: Could not stop container, proceeding with removal anyway."
    fi
  fi
fi

# ─── Remove container ────────────────────────────────────────────────────────

echo "==> Removing container $CONTAINER_NAME..."
container rm -f "$CONTAINER_NAME" 2>/dev/null || true

# ─── Clean up staging directories ────────────────────────────────────────────

rm -rf "$SCRIPT_DIR"/.stage-*

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

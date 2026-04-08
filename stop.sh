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
STOP_TIMEOUT=${STOP_TIMEOUT:-10}

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Run a command with a timeout. Returns 0 on success, 1 on timeout/failure.
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

# Kill the Virtualization.framework VM process backing a container.
kill_vm_process() {
  local name=$1
  local runtime_pid
  runtime_pid=$(pgrep -f "container-runtime-linux start --root.*--uuid ${name}$" || true)
  if [ -z "$runtime_pid" ]; then
    return 1
  fi
  # The VM process is a child of the runtime process
  local vm_pids
  vm_pids=$(pgrep -P "$runtime_pid" 2>/dev/null || true)
  if [ -n "$vm_pids" ]; then
    echo "==> Killing VM process(es): $vm_pids"
    kill -9 $vm_pids 2>/dev/null || true
  fi
  # Also kill the runtime itself
  echo "==> Killing runtime process: $runtime_pid"
  kill -9 "$runtime_pid" 2>/dev/null || true
  return 0
}

# Diagnose why the container is unresponsive. Prints a summary to stdout.
diagnose_container() {
  local name=$1
  echo ""
  echo "─── Diagnostics ───────────────────────────────────────────────"

  # VM resource usage (may hang too — give it 5s)
  local stats_json
  stats_json=$(run_with_timeout 5 container stats "$name" --no-stream --format json 2>/dev/null) || true
  if [ -n "$stats_json" ]; then
    local mem_used mem_limit mem_pct cpuUsec pids
    mem_used=$(echo "$stats_json" | grep -o '"memoryUsageBytes":[0-9]*' | cut -d: -f2)
    mem_limit=$(echo "$stats_json" | grep -o '"memoryLimitBytes":[0-9]*' | cut -d: -f2)
    pids=$(echo "$stats_json" | grep -o '"numProcesses":[0-9]*' | cut -d: -f2)

    if [ -n "$mem_used" ] && [ -n "$mem_limit" ] && [ "$mem_limit" -gt 0 ]; then
      mem_pct=$((mem_used * 100 / mem_limit))
      local mem_used_mb=$((mem_used / 1048576))
      local mem_limit_mb=$((mem_limit / 1048576))
      echo "  Memory: ${mem_used_mb} MiB / ${mem_limit_mb} MiB (${mem_pct}%)"
      if [ "$mem_pct" -ge 95 ]; then
        echo "  ${YELLOW}⚠ Memory near limit — likely OOM inside VM${NC}"
      fi
    fi
    [ -n "$pids" ] && echo "  Processes: $pids"
  else
    echo "  Stats: unavailable (VM unresponsive)"
  fi

  # Check kernel OOM log from boot log (always available via Virtualization.framework)
  local oom_lines
  oom_lines=$(container logs "$name" --boot -n 100 2>/dev/null | grep -i "oom-kill\|Out of memory\|invoked oom-killer" || true)
  if [ -n "$oom_lines" ]; then
    echo "  ${RED}OOM detected in VM kernel log:${NC}"
    echo "$oom_lines" | tail -3 | while IFS= read -r line; do
      echo "    $line"
    done
  fi

  # Host memory pressure
  local host_pressure
  host_pressure=$(memory_pressure 2>/dev/null | head -1 || true)
  if [ -n "$host_pressure" ]; then
    echo "  Host: $host_pressure"
  fi

  # Check if the Virtualization.framework process is stuck (high CPU = spinning)
  local runtime_pid
  runtime_pid=$(pgrep -f "container-runtime-linux start --root.*--uuid ${name}$" || true)
  if [ -n "$runtime_pid" ]; then
    local vm_pid vm_cpu
    vm_pid=$(pgrep -P "$runtime_pid" 2>/dev/null | head -1 || true)
    if [ -n "$vm_pid" ]; then
      vm_cpu=$(ps -p "$vm_pid" -o %cpu= 2>/dev/null | tr -d ' ' || true)
      if [ -n "$vm_cpu" ]; then
        echo "  VM process (PID $vm_pid): ${vm_cpu}% CPU"
        # Check if CPU is pegged (>300% on 4 cores = spinning)
        local cpu_int=${vm_cpu%%.*}
        if [ "${cpu_int:-0}" -ge 300 ]; then
          echo "  ${YELLOW}⚠ VM process consuming excessive CPU — likely stuck${NC}"
        fi
      fi
    fi
  fi

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

# ─── Stop container ──────────────────────────────────────────────────────────

STATE=$(container inspect "$CONTAINER_NAME" 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")

if [ "$STATE" != "running" ]; then
  # API might be stale — check for an orphaned VM process before giving up
  if kill_vm_process "$CONTAINER_NAME"; then
    echo "Killed orphaned VM process (API was unresponsive)."
    container rm -f "$CONTAINER_NAME" &>/dev/null || true
  else
    echo "Container is not running ($CONTAINER_NAME)"
  fi
  exit 0
fi

echo "==> Stopping container $CONTAINER_NAME..."

# Tier 1: graceful stop
if run_with_timeout "$STOP_TIMEOUT" container stop -t 5 "$CONTAINER_NAME" 2>/dev/null; then
  echo "Container stopped."
else
  # Graceful stop failed — capture diagnostics before escalating
  echo "==> Graceful stop timed out, collecting diagnostics..."
  diagnose_container "$CONTAINER_NAME"

  # Tier 2: force kill via container CLI
  if run_with_timeout "$STOP_TIMEOUT" container kill "$CONTAINER_NAME" 2>/dev/null; then
    echo "Container killed."
  # Tier 3: kill the VM process directly (resource-depleted VM)
  elif kill_vm_process "$CONTAINER_NAME"; then
    echo "VM process killed (container was unresponsive)."
    sleep 1
    container rm -f "$CONTAINER_NAME" 2>/dev/null || true
    echo "Container state cleaned up."
  else
    echo "ERROR: Could not stop container. No matching VM process found."
    echo "  Try: ps aux | grep VirtualMachine"
    exit 1
  fi
fi

# ─── Clean up staging directories ────────────────────────────────────────────

rm -rf "$SCRIPT_DIR"/.stage-*

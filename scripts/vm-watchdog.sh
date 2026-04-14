#!/bin/bash
set -e

LOG=/var/log/vm-watchdog.log
POLL="${WATCHDOG_POLL:-5}"
MEM_CRIT_MB="${WATCHDOG_MEM_CRIT_MB:-400}"
MEM_RESUME_MB="${WATCHDOG_MEM_RESUME_MB:-1200}"
SWAP_DIR=/var/swap
SWAP_CHUNK_MB=256
SWAP_DISK_MIN_MB=2048
SWAP_ESCALATE_SEC=30
SWAP_KILL_SEC=10

_parse_mb() {
    case "$1" in
        *[Gg]) echo $(( ${1%[Gg]} * 1024 )) ;;
        *[Mm]) echo ${1%[Mm]} ;;
        *)     echo "$1" ;;
    esac
}
SWAP_MAX_MB=$(_parse_mb "${SWAP_SIZE:-2G}")

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG" >&2; }

mem_avail_mb() { awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo; }

swap_free_mb() {
    awk '/^SwapFree:/ {printf "%d", $2/1024}' /proc/meminfo
}

# Find heaviest processes by RSS, skipping system/shell processes
heavy_pids() {
    for d in /proc/[0-9]*; do
        local pid="${d##*/}"
        [ "$pid" = "$$" ] && continue
        local comm rss_kb
        comm=$(cat "$d/comm" 2>/dev/null) || continue
        case "$comm" in
            bash|sh|sleep|vm-watchdog|entrypoint.sh|init|sudo|sshd|vminitd|login|getty) continue ;;
        esac
        rss_kb=$(awk '/^VmRSS:/ {print $2}' "$d/status" 2>/dev/null) || continue
        [ -z "$rss_kb" ] && continue
        [ "$rss_kb" -lt 10000 ] 2>/dev/null && continue
        echo "$pid $rss_kb $comm"
    done | sort -k2 -rn | head -5 | awk '{print $1}'
}

# Raise OOM score on heavy non-shell processes so OOM killer targets them first
raise_oom_scores() {
    for d in /proc/[0-9]*; do
        local pid="${d##*/}"
        local comm rss_kb
        comm=$(cat "$d/comm" 2>/dev/null) || continue
        case "$comm" in
            bash|sh|sleep|vm-watchdog|entrypoint.sh|init|sudo|sshd|vminitd|login|getty) continue ;;
        esac
        rss_kb=$(awk '/^VmRSS:/ {print $2}' "$d/status" 2>/dev/null) || continue
        [ -z "$rss_kb" ] && continue
        [ "$rss_kb" -lt 51200 ] 2>/dev/null && continue
        echo 500 > "$d/oom_score_adj" 2>/dev/null || true
    done
}

# ─── Dynamic swap growth ────────────────────────────────────────────────────
# Resume numbering from previous session (swap0 is entrypoint, swap1+ are ours)
SWAP_NEXT=$(ls "$SWAP_DIR"/swap* 2>/dev/null | wc -l)

grow_swap() {
    local f="$SWAP_DIR/swap${SWAP_NEXT}"
    # Check total swap doesn't exceed ceiling
    local total_swap_mb
    total_swap_mb=$(awk '/^SwapTotal:/ {printf "%d", $2/1024}' /proc/meminfo)
    if [ "$total_swap_mb" -ge "$SWAP_MAX_MB" ] 2>/dev/null; then
        log "SWAP at ceiling (${total_swap_mb}MB / ${SWAP_MAX_MB}MB)"
        return 1
    fi
    # Check disk space
    local disk_avail_mb
    disk_avail_mb=$(df -m /var 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$disk_avail_mb" ] && [ "$disk_avail_mb" -lt "$((SWAP_DISK_MIN_MB + SWAP_CHUNK_MB))" ]; then
        log "SWAP disk low (${disk_avail_mb}MB free, need ${SWAP_DISK_MIN_MB}MB reserve)"
        return 1
    fi
    dd if=/dev/zero of="$f" bs=1M count="$SWAP_CHUNK_MB" 2>/dev/null || return 1
    chmod 600 "$f"
    mkswap "$f" >/dev/null 2>&1 || return 1
    swapon "$f" 2>/dev/null || return 1
    SWAP_NEXT=$((SWAP_NEXT + 1))
    log "SWAP grew +${SWAP_CHUNK_MB}MB (file: swap$((SWAP_NEXT - 1)))"
    return 0
}

# ─── Process throttling ─────────────────────────────────────────────────────
THROTTLED=()
THROTTLING=false
THROTTLE_TIME=0

throttle() {
    # Drop caches first — may free enough without stopping anything
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

    for pid in $(heavy_pids); do
        if kill -STOP "$pid" 2>/dev/null; then
            THROTTLED+=("$pid")
            local c
            c=$(cat "/proc/$pid/comm" 2>/dev/null || echo "?")
            log "STOP pid=$pid ($c)"
        fi
    done
    THROTTLING=true
    THROTTLE_TIME=0
}

unthrottle() {
    for pid in "${THROTTLED[@]}"; do
        if kill -CONT "$pid" 2>/dev/null; then
            local c
            c=$(cat "/proc/$pid/comm" 2>/dev/null || echo "?")
            log "CONT pid=$pid ($c)"
        fi
    done
    THROTTLED=()
    THROTTLING=false
    THROTTLE_TIME=0
}

# Escalate: SIGTERM the heaviest stopped process
escalate_term() {
    if [ ${#THROTTLED[@]} -eq 0 ]; then return; fi
    local pid="${THROTTLED[0]}"
    local c
    c=$(cat "/proc/$pid/comm" 2>/dev/null || echo "?")
    # Resume it briefly so it can handle SIGTERM
    kill -CONT "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
    log "TERM pid=$pid ($c) — memory did not recover after ${SWAP_ESCALATE_SEC}s"
    # Remove from throttled list
    THROTTLED=("${THROTTLED[@]:1}")
}

# Escalate: SIGKILL the heaviest stopped process
escalate_kill() {
    if [ ${#THROTTLED[@]} -eq 0 ]; then return; fi
    local pid="${THROTTLED[0]}"
    local c
    c=$(cat "/proc/$pid/comm" 2>/dev/null || echo "?")
    kill -KILL "$pid" 2>/dev/null || true
    log "KILL pid=$pid ($c) — SIGTERM did not free memory after ${SWAP_KILL_SEC}s"
    THROTTLED=("${THROTTLED[@]:1}")
}

# Clean up on exit — resume any stopped processes
trap 'unthrottle' EXIT

log "started (crit=${MEM_CRIT_MB}MB resume=${MEM_RESUME_MB}MB poll=${POLL}s)"

while true; do
    mem=$(mem_avail_mb)
    swap_free=$(swap_free_mb)

    # ─── Swap growth: add a chunk when free swap drops below chunk size ──
    if [ "$swap_free" -lt "$SWAP_CHUNK_MB" ] 2>/dev/null; then
        grow_swap || true
    fi

    # Raise OOM scores on heavy processes when memory is getting low
    if [ "$mem" -lt "$MEM_RESUME_MB" ] 2>/dev/null; then
        raise_oom_scores
    fi

    # ─── Memory management ───────────────────────────────────────────────
    if [ "$mem" -lt "$MEM_CRIT_MB" ]; then
        if [ "$THROTTLING" = false ]; then
            log "CRITICAL ${mem}MB available — throttling"
            throttle
        else
            THROTTLE_TIME=$((THROTTLE_TIME + POLL))
            # Escalation: SIGTERM after SWAP_ESCALATE_SEC, SIGKILL after + SWAP_KILL_SEC
            local kill_at=$((SWAP_ESCALATE_SEC + SWAP_KILL_SEC))
            if [ "$THROTTLE_TIME" -ge "$kill_at" ]; then
                escalate_kill
                THROTTLE_TIME=0  # Reset to target next process if needed
            elif [ "$THROTTLE_TIME" -ge "$SWAP_ESCALATE_SEC" ] && [ "$THROTTLE_TIME" -lt "$((SWAP_ESCALATE_SEC + POLL))" ]; then
                escalate_term
            fi
        fi
    elif [ "$mem" -gt "$MEM_RESUME_MB" ] && [ "$THROTTLING" = true ]; then
        log "RECOVERED ${mem}MB available — resuming"
        unthrottle
    fi

    sleep "$POLL"
done

#!/bin/bash
set -e

# ─── Ensure .bashrc exists (volume mount hides image's /home/claude) ────────
if [ ! -f /home/claude/.bashrc ] && [ -f /etc/skel/.bashrc ]; then
    cp /etc/skel/.bashrc /home/claude/.bashrc
    chown claude:claude /home/claude/.bashrc
fi

# ─── Swap (direct files on ext4 rootfs) ──────────────────────────────────────
# Creates a 256MB initial swapfile. The watchdog grows it on demand
# up to SWAP_SIZE when memory pressure increases.
SWAP_DIR=/var/swap
mkdir -p "$SWAP_DIR"
if [ ! -f "$SWAP_DIR/swap0" ]; then
    dd if=/dev/zero of="$SWAP_DIR/swap0" bs=1M count=256 2>/dev/null
    chmod 600 "$SWAP_DIR/swap0"
    mkswap "$SWAP_DIR/swap0" >/dev/null 2>&1
fi
# Activate all swap files (includes any grown by watchdog in previous session)
for f in "$SWAP_DIR"/swap*; do
    [ -f "$f" ] && swapon "$f" 2>/dev/null || true
done
echo 10 > /proc/sys/vm/swappiness 2>/dev/null || true

# ─── Shell protection (cgroup v2) ──────────────────────────────────────────
# Reserve memory + CPU for interactive sessions so the user always has
# a responsive terminal, even under extreme resource pressure.
SHELL_RESERVE_MB="${SHELL_RESERVE_MB:-256}"
CG=/sys/fs/cgroup
if [ -f "$CG/cgroup.controllers" ]; then
    mkdir -p "$CG/init" "$CG/shell" "$CG/system" 2>/dev/null || true
    # Move all root-cgroup processes (incl. vminitd) to init/
    # Required before enabling subtree controllers (no-internal-process rule)
    cat "$CG/cgroup.procs" 2>/dev/null | while read -r pid; do
        echo "$pid" > "$CG/init/cgroup.procs" 2>/dev/null || true
    done
    if echo "+memory +cpu" > "$CG/cgroup.subtree_control" 2>/dev/null; then
        echo $$ > "$CG/system/cgroup.procs" 2>/dev/null || true
        echo $(($SHELL_RESERVE_MB * 1024 * 1024)) > "$CG/shell/memory.min" 2>/dev/null || true
        echo 10000 > "$CG/shell/cpu.weight" 2>/dev/null || true
        chown claude:claude "$CG/shell/cgroup.procs" 2>/dev/null || true
        echo "Shell protection: cgroup active (${SHELL_RESERVE_MB}MB reserved)"
    else
        echo "Shell protection: cgroup unavailable, OOM-score fallback only"
    fi
fi

# ─── Shell protection profile script ────────────────────────────────────────
cat > /etc/profile.d/shell-protect.sh << 'SHELL_PROTECT'
if [ -d /sys/fs/cgroup/shell ]; then
    sudo sh -c "echo $$ > /sys/fs/cgroup/shell/cgroup.procs" 2>/dev/null || true
fi
sudo sh -c "echo -999 > /proc/$$/oom_score_adj; renice -20 $$" 2>/dev/null || true
SHELL_PROTECT

# ─── Watchdog ────────────────────────────────────────────────────────────────
/usr/local/bin/vm-watchdog.sh &

exec sleep infinity

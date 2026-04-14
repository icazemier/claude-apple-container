FROM alpine:latest

# ─── System packages ─────────────────────────────────────────────────────────

RUN apk update && apk add --no-cache \
    bash \
    bash-completion \
    build-base \
    cairo-dev \
    chromium \
    curl \
    e2fsprogs \
    giflib-dev \
    git \
    jpeg-dev \
    librsvg-dev \
    nodejs \
    npm \
    nss \
    openssh-client \
    pango-dev \
    pixman-dev \
    py3-pip \
    python3 \
    sudo \
    shadow \
    vim \
    wget \
    yarn

# ─── Azure CLI ────────────────────────────────────────────────────────────────

RUN python3 -m venv /opt/az \
    && /opt/az/bin/pip install --quiet azure-cli \
    && ln -s /opt/az/bin/az /usr/local/bin/az

# ─── Create claude user ──────────────────────────────────────────────────────

RUN adduser -D -s /bin/bash -h /home/claude claude \
    && echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude \
    && chmod 0440 /etc/sudoers.d/claude

# ─── Claude Code native binary ──────────────────────────────────────────────
# Installed at runtime (not build time) because the binary's install
# subcommand OOM-kills in the resource-constrained builder VM.
# The profile.d script below installs on first login and adds to PATH.

RUN cat > /etc/profile.d/claude-code.sh << 'CLAUDE_CODE'
export PATH="$HOME/.local/bin:$PATH"

# Install native Claude Code binary on first login if missing
if [ ! -x "$HOME/.local/bin/claude" ]; then
    echo "Installing Claude Code native binary..."
    curl -fsSL https://claude.ai/install.sh | bash
fi
CLAUDE_CODE

# ─── nm-local: work around virtio-fs node_modules issue ──────────────────────
# Placed in /etc/profile.d/ so it survives volume mounts over /home/claude.

RUN cat > /etc/profile.d/nm-local.sh << 'NMLOCAL'
# Apple Containers uses virtio-fs for ALL filesystems (rootfs, volumes,
# shared folders). virtio-fs can't handle node_modules' deeply nested
# symlink-heavy structure. nm-local bind-mounts a directory from a
# loop-mounted ext4 sparse image onto ./node_modules — bypasses virtio-fs
# without eating RAM. Bind mount is transparent to yarn/npm (looks like a
# real directory). The image persists across container restarts.
NM_IMG=/home/claude/.nm-local.img
NM_MNT=/mnt/nm

_nm_ensure_mount() {
    if ! mountpoint -q "$NM_MNT" 2>/dev/null; then
        if [ ! -f "$NM_IMG" ]; then
            truncate -s 20G "$NM_IMG"
            mkfs.ext4 -q -m 0 "$NM_IMG"
            echo "Created nm-local ext4 image (20G sparse)"
        fi
        sudo mkdir -p "$NM_MNT"
        sudo mount -o loop "$NM_IMG" "$NM_MNT"
        sudo chown claude:claude "$NM_MNT"
    fi
}

nm-local() {
    local hash=$(echo "$PWD" | md5sum | cut -c1-12)
    local local_nm="$NM_MNT/$hash"
    # Already bind-mounted?
    if mountpoint -q node_modules 2>/dev/null; then
        echo "node_modules already mounted → $local_nm"
        return 0
    fi
    _nm_ensure_mount
    mkdir -p "$local_nm"
    # Ensure node_modules directory exists as a mount target
    if [ -L node_modules ]; then
        rm node_modules
    fi
    if [ ! -d node_modules ]; then
        mkdir node_modules
    fi
    sudo mount --bind "$local_nm" node_modules
    echo "node_modules → $local_nm (ext4 bind mount)"
}

# Wipe node_modules for current project and re-mount
nm-clean() {
    local hash=$(echo "$PWD" | md5sum | cut -c1-12)
    local local_nm="$NM_MNT/$hash"
    _nm_ensure_mount
    if mountpoint -q node_modules 2>/dev/null; then
        sudo umount node_modules
    fi
    if [ -d "$local_nm" ]; then
        rm -rf "$local_nm"
        echo "Cleaned $local_nm"
    fi
    mkdir -p "$local_nm"
    if [ ! -d node_modules ]; then
        mkdir node_modules
    fi
    sudo mount --bind "$local_nm" node_modules
    echo "node_modules → $local_nm (ext4 bind mount, clean)"
}

yarn() {
    if [[ "$PWD" == /home/claude/* ]] && ! mountpoint -q node_modules 2>/dev/null; then
        nm-local
    fi
    command yarn "$@"
}

npm() {
    if [[ "$PWD" == /home/claude/* ]] && ! mountpoint -q node_modules 2>/dev/null; then
        nm-local
    fi
    command npm "$@"
}
NMLOCAL

# ─── Entrypoint: swap + watchdog + sleep ─────────────────────────────────────

RUN cat > /usr/local/bin/entrypoint.sh << 'ENTRYPOINT_SCRIPT'
#!/bin/bash
set -e

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

# ─── Watchdog ────────────────────────────────────────────────────────────────
/usr/local/bin/vm-watchdog.sh &

exec sleep infinity
ENTRYPOINT_SCRIPT
RUN chmod +x /usr/local/bin/entrypoint.sh

# ─── VM watchdog: memory monitor + process throttler ─────────────────────────

RUN cat > /usr/local/bin/vm-watchdog.sh << 'WATCHDOG_SCRIPT'
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
WATCHDOG_SCRIPT
RUN chmod +x /usr/local/bin/vm-watchdog.sh

# ─── watchdog-status command ─────────────────────────────────────────────────

RUN cat > /etc/profile.d/vm-watchdog-status.sh << 'WATCHDOG_STATUS'
watchdog-status() {
    echo "─── Memory ───"
    awk '/^MemTotal:|^MemAvailable:|^SwapTotal:|^SwapFree:/ {
        printf "  %-16s %6d MB\n", $1, $2/1024
    }' /proc/meminfo
    echo "─── Swap Files ───"
    cat /proc/swaps 2>/dev/null
    if [ -d /var/swap ]; then
        echo "  files: $(ls /var/swap/swap* 2>/dev/null | wc -l | tr -d ' ')"
        echo "  disk: $(df -h /var 2>/dev/null | awk 'NR==2 {printf "%s used / %s (%s free)", $3, $2, $4}')"
    fi
    echo "─── Shell Protection ───"
    if [ -d /sys/fs/cgroup/shell ]; then
        local min_bytes min_mb
        min_bytes=$(cat /sys/fs/cgroup/shell/memory.min 2>/dev/null || echo 0)
        min_mb=$((min_bytes / 1024 / 1024))
        echo "  cgroup: active (memory.min=${min_mb}MB cpu.weight=$(cat /sys/fs/cgroup/shell/cpu.weight 2>/dev/null || echo '?'))"
        echo "  shell procs: $(cat /sys/fs/cgroup/shell/cgroup.procs 2>/dev/null | wc -l | tr -d ' ')"
    else
        echo "  cgroup: not available (OOM-score fallback only)"
    fi
    echo "  oom_score_adj: $(cat /proc/$$/oom_score_adj 2>/dev/null || echo 'unknown')"
    echo "─── Watchdog Log (last 15) ───"
    tail -15 /var/log/vm-watchdog.log 2>/dev/null || echo "  (no log yet)"
}
WATCHDOG_STATUS

# ─── Shell protection: join reserved cgroup + OOM/CPU priority ─────────────

RUN cat > /etc/profile.d/shell-protect.sh << 'SHELL_PROTECT'
# Join protected cgroup if available (set up by entrypoint)
if [ -d /sys/fs/cgroup/shell ]; then
    sudo sh -c "echo $$ > /sys/fs/cgroup/shell/cgroup.procs" 2>/dev/null || true
fi
# OOM immunity + highest scheduling priority (works even without cgroups)
sudo sh -c "echo -999 > /proc/$$/oom_score_adj; renice -20 $$" 2>/dev/null || true
SHELL_PROTECT

# ─── MCP servers (globally available for Claude Code) ───────────────────────

RUN npm install -g @azure-devops/mcp @playwright/mcp

USER claude
WORKDIR /home/claude

# ─── Playwright (using Alpine's native Chromium) ─────────────────────────────

ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium-browser

# ─── Clean up caches ─────────────────────────────────────────────────────────

RUN npm cache clean --force \
    && yarn cache clean 2>/dev/null || true

# ─── Shell configuration ─────────────────────────────────────────────────────

RUN cat >> /home/claude/.bashrc << 'BASHRC'

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# ─── Source image-level profile scripts (survive volume mounts) ───────────────
for f in /etc/profile.d/*.sh; do [ -r "$f" ] && . "$f"; done

# ─── History ──────────────────────────────────────────────────────────────────
HISTCONTROL=ignoreboth
shopt -s histappend
HISTSIZE=1000
HISTFILESIZE=2000
shopt -s checkwinsize

# ─── Playwright ───────────────────────────────────────────────────────────────
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
export PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium-browser

# ─── Aliases ──────────────────────────────────────────────────────────────────
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# ─── Prompt ───────────────────────────────────────────────────────────────────
parse_git_branch() {
    git branch 2>/dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/ (\1)/'
}
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[33m\]$(parse_git_branch)\[\033[00m\]\$ '

# ─── Bash completion ─────────────────────────────────────────────────────────
if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
fi

# ─── SSH agent ────────────────────────────────────────────────────────────────
SSH_AGENT_SOCK="$HOME/.ssh/agent.sock"
export SSH_AUTH_SOCK="$SSH_AGENT_SOCK"
if [ ! -S "$SSH_AGENT_SOCK" ] || ! ssh-add -l &>/dev/null 2>&1; then
    rm -f "$SSH_AGENT_SOCK"
    eval "$(ssh-agent -a "$SSH_AGENT_SOCK" -s)" > /dev/null
fi
# Auto-add all private keys to the agent
grep -slR "PRIVATE" ~/.ssh/ 2>/dev/null | xargs -r ssh-add 2>/dev/null

# ─── Welcome ──────────────────────────────────────────────────────────────────
if [ -z "$WELCOMED" ]; then
    export WELCOMED=1
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  claude-apple-container                                 ║"
    echo "║                                                         ║"
    echo "║  To get started, run: claude                            ║"
    echo "║                                                         ║"
    echo "║  Authentication options:                                 ║"
    echo "║    1. Claude.ai subscription — claude will prompt you   ║"
    echo "║       to log in via the browser on first run            ║"
    echo "║    2. API key — export ANTHROPIC_API_KEY=your-key       ║"
    echo "║                                                         ║"
    echo "║  Available tools:                                       ║"
    echo "║    claude         Claude Code CLI                       ║"
    echo "║    az             Azure CLI                             ║"
    echo "║    node           $(node --version 2>/dev/null || echo 'not found')                              ║"
    echo "║    git            $(git --version 2>/dev/null | cut -d' ' -f3 || echo 'not found')                            ║"
    echo "║                                                         ║"
    echo "║  MCP servers (globally installed):                      ║"
    echo "║    @azure-devops/mcp    Azure DevOps                    ║"
    echo "║    @playwright/mcp      Browser automation              ║"
    echo "║                                                         ║"
    echo "║  Before yarn/npm install, run: nm-local                 ║"
    echo "║  (moves node_modules to native fs — avoids virtio-fs)   ║"
    echo "║                                                         ║"
    echo "║  VM health: watchdog-status                             ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
fi
BASHRC

# ─── Default command (runs as root for swap/watchdog; shell.sh enters as claude) ─

USER root
CMD ["/usr/local/bin/entrypoint.sh"]

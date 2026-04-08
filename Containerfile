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

# ─── Swap (ext4 on loop device — same proven pattern as nm-local) ────────────
# Creates a small initial swapfile (256MB). The watchdog grows it on demand
# up to SWAP_SIZE when memory pressure increases.
SWAP_IMG=/var/swap.img
SWAP_MNT=/mnt/swap
SWAP_SIZE="${SWAP_SIZE:-2G}"
if ! mountpoint -q "$SWAP_MNT" 2>/dev/null; then
    if [ ! -f "$SWAP_IMG" ]; then
        truncate -s "$SWAP_SIZE" "$SWAP_IMG"
        mkfs.ext4 -q -m 0 "$SWAP_IMG"
    fi
    mkdir -p "$SWAP_MNT"
    mount -o loop "$SWAP_IMG" "$SWAP_MNT" 2>/dev/null || true
fi
if mountpoint -q "$SWAP_MNT" 2>/dev/null; then
    # Create initial swap if first boot
    if [ ! -f "$SWAP_MNT/swap0" ]; then
        dd if=/dev/zero of="$SWAP_MNT/swap0" bs=1M count=256 status=none 2>/dev/null
        chmod 600 "$SWAP_MNT/swap0"
        mkswap -q "$SWAP_MNT/swap0" >/dev/null 2>&1
    fi
    # Activate all swap files (includes any grown by watchdog in previous session)
    for f in "$SWAP_MNT"/swap*; do
        [ -f "$f" ] && swapon "$f" 2>/dev/null || true
    done
    echo 10 > /proc/sys/vm/swappiness 2>/dev/null || true
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
SWAP_MNT=/mnt/swap
SWAP_CHUNK_MB=256
SWAP_ESCALATE_SEC=30
SWAP_KILL_SEC=10

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

# ─── Dynamic swap growth ────────────────────────────────────────────────────
# Resume numbering from previous session (swap0 is entrypoint, swap1+ are ours)
SWAP_NEXT=$(ls "$SWAP_MNT"/swap* 2>/dev/null | wc -l)

SWAP_HOST_MIN_MB=2048  # Don't eat into host disk below this threshold

grow_swap() {
    if ! mountpoint -q "$SWAP_MNT" 2>/dev/null; then return 1; fi
    local f="$SWAP_MNT/swap${SWAP_NEXT}"
    # Check space on ext4 image (the ceiling)
    local img_avail_mb
    img_avail_mb=$(df -m "$SWAP_MNT" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$img_avail_mb" ] || [ "$img_avail_mb" -lt "$SWAP_CHUNK_MB" ]; then
        log "SWAP no space left on ext4 image (${img_avail_mb:-0}MB free)"
        return 1
    fi
    # Check host disk space (rootfs is virtio-fs → host filesystem)
    local host_avail_mb
    host_avail_mb=$(df -m /var 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$host_avail_mb" ] && [ "$host_avail_mb" -lt "$((SWAP_HOST_MIN_MB + SWAP_CHUNK_MB))" ]; then
        log "SWAP host disk low (${host_avail_mb}MB free, need ${SWAP_HOST_MIN_MB}MB reserve)"
        return 1
    fi
    dd if=/dev/zero of="$f" bs=1M count="$SWAP_CHUNK_MB" status=none 2>/dev/null || return 1
    chmod 600 "$f"
    mkswap -q "$f" >/dev/null 2>&1 || return 1
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
    swapon --show 2>/dev/null || echo "  (none)"
    if mountpoint -q /mnt/swap 2>/dev/null; then
        echo "  ext4 image:"
        df -h /mnt/swap 2>/dev/null | awk 'NR==2 {printf "    used %s / %s (%s free)\n", $3, $2, $4}'
    fi
    echo "─── Watchdog Log (last 15) ───"
    tail -15 /var/log/vm-watchdog.log 2>/dev/null || echo "  (no log yet)"
}
WATCHDOG_STATUS

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

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

# ─── Global npm packages (as root, before user switch) ───────────────────────

RUN npm install -g \
    @anthropic-ai/claude-code \
    claude-flow@alpha

# ─── Create claude user ──────────────────────────────────────────────────────

RUN adduser -D -s /bin/bash -h /home/claude claude \
    && echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude \
    && chmod 0440 /etc/sudoers.d/claude


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
    echo "║    claude-flow    Multi-agent orchestrator               ║"
    echo "║    az             Azure CLI                             ║"
    echo "║    node           $(node --version 2>/dev/null || echo 'not found')                              ║"
    echo "║    git            $(git --version 2>/dev/null | cut -d' ' -f3 || echo 'not found')                            ║"
    echo "║                                                         ║"
    echo "║  Before yarn/npm install, run: nm-local                 ║"
    echo "║  (moves node_modules to native fs — avoids virtio-fs)   ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
fi
BASHRC

# ─── Default command ─────────────────────────────────────────────────────────

CMD ["sleep", "infinity"]

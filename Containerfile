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

RUN cat > /etc/profile.d/claude-code.sh << 'CLAUDE_CODE'
export PATH="$HOME/.local/bin:$PATH"

# Install native Claude Code binary on first login if missing
if [ ! -x "$HOME/.local/bin/claude" ]; then
    echo "Installing Claude Code native binary..."
    curl -fsSL https://claude.ai/install.sh | bash
fi
CLAUDE_CODE

# ─── nm-local: work around virtio-fs node_modules issue ──────────────────────

COPY scripts/nm-local.sh /etc/profile.d/nm-local.sh

# ─── Entrypoint + watchdog scripts ──────────────────────────────────────────

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/vm-watchdog.sh /usr/local/bin/vm-watchdog.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/vm-watchdog.sh

# ─── watchdog-status command ─────────────────────────────────────────────────

RUN cat > /etc/profile.d/vm-watchdog-status.sh << 'WATCHDOG_STATUS'
watchdog-status() {
    echo "--- Memory ---"
    awk '/^MemTotal:|^MemAvailable:|^SwapTotal:|^SwapFree:/ {
        printf "  %-16s %6d MB\n", $1, $2/1024
    }' /proc/meminfo
    echo "--- Swap ---"
    cat /proc/swaps
    echo "--- Watchdog Log (last 15) ---"
    tail -15 /var/log/vm-watchdog.log 2>/dev/null || echo "  (no log yet)"
}
WATCHDOG_STATUS

# ─── MCP servers ─────────────────────────────────────────────────────────────
# Installed at runtime by up.sh (buildkit VM has unreliable DNS)

USER claude
WORKDIR /home/claude

# ─── Playwright (using Alpine's native Chromium) ─────────────────────────────

ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium-browser

# ─── Clean up caches ─────────────────────────────────────────────────────────

RUN npm cache clean --force \
    && yarn cache clean 2>/dev/null || true

# ─── Shell configuration ─────────────────────────────────────────────────────
# Stored in /etc/skel — entrypoint copies to /home/claude/ if missing
# (volume mount hides image-level /home/claude files)

COPY scripts/bashrc.sh /etc/skel/.bashrc

# ─── Default command (runs as root for swap/watchdog; shell.sh enters as claude) ─

USER root
CMD ["/usr/local/bin/entrypoint.sh"]

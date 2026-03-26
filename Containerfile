FROM alpine:latest

# ─── System packages ─────────────────────────────────────────────────────────

RUN apk update && apk add --no-cache \
    bash \
    build-base \
    chromium \
    curl \
    git \
    nss \
    python3 \
    sudo \
    shadow

# ─── Create claude user ──────────────────────────────────────────────────────

RUN adduser -D -s /bin/bash -h /home/claude claude \
    && echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude \
    && chmod 0440 /etc/sudoers.d/claude

# ─── Node.js 22 via nvm ──────────────────────────────────────────────────────

USER claude
WORKDIR /home/claude

ENV NVM_DIR=/home/claude/.nvm
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash \
    && . "$NVM_DIR/nvm.sh" \
    && nvm install 22 \
    && nvm alias default 22 \
    && nvm use default

# ─── Global npm packages ─────────────────────────────────────────────────────

ENV PATH="/home/claude/.nvm/versions/node/v22/bin:$PATH"
RUN . "$NVM_DIR/nvm.sh" \
    && npm install -g \
       yarn \
       @anthropic-ai/claude-code \
       claude-flow@alpha

# ─── Playwright (using Alpine's native Chromium) ─────────────────────────────

ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium-browser
RUN . "$NVM_DIR/nvm.sh" \
    && npx playwright install-deps 2>/dev/null || true

# ─── Shell configuration ─────────────────────────────────────────────────────

RUN cat >> /home/claude/.bashrc << 'BASHRC'

# ─── nvm ──────────────────────────────────────────────────────────────────────
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# ─── Playwright ───────────────────────────────────────────────────────────────
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
export PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium-browser

# ─── Prompt ───────────────────────────────────────────────────────────────────
parse_git_branch() {
    git branch 2>/dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/ (\1)/'
}
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[33m\]$(parse_git_branch)\[\033[00m\]\$ '

# ─── Welcome ──────────────────────────────────────────────────────────────────
if [ -z "$WELCOMED" ]; then
    export WELCOMED=1
    echo ""
    echo "  claude-apple-container"
    echo "  ─────────────────────"
    echo "  claude     — Claude Code CLI"
    echo "  claude-flow — Multi-agent orchestrator"
    echo "  node       — $(node --version 2>/dev/null || echo 'not found')"
    echo "  git        — $(git --version 2>/dev/null | cut -d' ' -f3 || echo 'not found')"
    echo "  chromium   — $(chromium-browser --version 2>/dev/null | head -1 || echo 'not found')"
    echo ""
fi
BASHRC

# ─── Default command ─────────────────────────────────────────────────────────

CMD ["bash", "-l"]

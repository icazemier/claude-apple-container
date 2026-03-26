FROM alpine:latest

# ─── System packages ─────────────────────────────────────────────────────────

RUN apk update && apk add --no-cache \
    bash \
    bash-completion \
    build-base \
    cairo-dev \
    chromium \
    curl \
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
    python3 \
    sudo \
    shadow \
    vim \
    wget \
    yarn

# ─── Global npm packages (as root, before user switch) ───────────────────────

RUN npm install -g \
    @anthropic-ai/claude-code \
    claude-flow@alpha

# ─── Create claude user ──────────────────────────────────────────────────────

RUN adduser -D -s /bin/bash -h /home/claude claude \
    && echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude \
    && chmod 0440 /etc/sudoers.d/claude

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
    echo "║    node           $(node --version 2>/dev/null || echo 'not found')                              ║"
    echo "║    git            $(git --version 2>/dev/null | cut -d' ' -f3 || echo 'not found')                            ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
fi
BASHRC

# ─── Default command ─────────────────────────────────────────────────────────

CMD ["sleep", "infinity"]

# claude-apple-container

A Claude Code development environment running in Apple's native Containerization framework — no Docker Desktop, no QEMU, no VirtualBox.

## What's Included

- **Alpine Linux** (~5 MB base, ARM64)
- **Node.js 22** via nvm
- **Claude Code** (`@anthropic-ai/claude-code`)
- **claude-flow** orchestrator (`claude-flow@alpha`)
- **Playwright** with Chromium (Alpine native build)
- Build essentials, git, curl, vim, python3

## Prerequisites

| Requirement | Detail |
|---|---|
| Hardware | Apple Silicon (M1/M2/M3/M4) |
| macOS | 15.0 (Sequoia) minimum |
| Apple `container` CLI | Install from [GitHub releases](https://github.com/apple/container/releases) |

That's it. No Docker Desktop, no VirtualBox, no Homebrew dependencies.

## Quick Start

```bash
git clone git@github.com:icazemier/claude-apple-container.git
cd claude-apple-container
cp .env.example .env
# Edit .env to set SHARED_FOLDER if needed

./up.sh
```

First run builds the container image (takes a few minutes). Subsequent starts take seconds.

## Daily Commands

```bash
./up.sh          # Start container (builds image on first run)
./stop.sh        # Stop container (state preserved)
./shell.sh       # Open a shell as the claude user
./destroy.sh     # Remove container (keeps volume + image for fast rebuild)
./destroy.sh --all  # Remove everything (volume + image)
```

**Inside the container:**
```bash
claude           # Launch Claude Code
claude-flow      # Launch claude-flow orchestrator
```

## Authenticate Claude Code

Inside the container (`./shell.sh`), run:

```bash
claude
```

You have two authentication options:

1. **Claude.ai subscription** — `claude` will prompt you to log in via the browser on first run
2. **API key** — set it first:
   ```bash
   export ANTHROPIC_API_KEY=your-key-here
   claude
   ```
   To make the API key permanent:
   ```bash
   echo 'export ANTHROPIC_API_KEY=your-key-here' >> ~/.bashrc
   ```

## Configuration

Copy `.env.example` to `.env` to customise:

```bash
cp .env.example .env
```

| Variable | Default | Description |
|---|---|---|
| `SHARED_FOLDER` | _(none)_ | Host path mounted at `/home/claude/shared` in the container |
| `FORWARDED_PORTS` | _(none)_ | Comma-separated ports to forward, e.g. `3000,5173` |
| `CONTAINER_NAME` | `claude-dev` | Name for the container instance |

Changes take effect after `./stop.sh && ./up.sh`.

## Shared Folder

Set `SHARED_FOLDER` in `.env`:

```
SHARED_FOLDER=/Users/you/myproject
```

The directory appears at `/home/claude/shared` inside the container. Use your host IDE/editor to edit files, let Claude Code in the container handle execution, builds, and tests.

## State Persistence

| What | Survives `stop`/`start`? | Survives `destroy` + `up`? |
|---|---|---|
| Installed packages (`apk add ...`) | Yes | No — add to Containerfile instead |
| `/home/claude` (SSH keys, config, history) | Yes | Yes — stored on named volume |
| Project files in shared folder | Yes | Yes — lives on host |
| Base tooling (Node.js, Claude Code, etc.) | Yes | Yes — part of the image |

## Installing Additional Packages

```bash
./shell.sh
sudo apk add python3 redis
```

Packages persist across `stop`/`start`. They are lost on `destroy` + `up` — if you need them permanently, add them to the `Containerfile` and rebuild:

```bash
./destroy.sh
./up.sh
```

## Connecting to Host Services

Each container gets its own IP address. Host services are reachable from inside the container via DNS:

```bash
# On the host (one-time setup):
sudo container system dns create host.container.internal --localhost

# Inside the container:
curl http://host.container.internal:3000
```

| Service | Container connection string |
|---|---|
| MongoDB | `mongodb://host.container.internal:27017` |
| Redis | `redis://host.container.internal:6379` |
| PostgreSQL | `postgresql://user:pass@host.container.internal:5432/db` |
| Any HTTP API | `http://host.container.internal:<port>` |

## Port Forwarding

Set `FORWARDED_PORTS` in `.env` to expose container services on the host:

```
FORWARDED_PORTS=3000,3001,5173
```

Services are reachable at `localhost:<port>` on the host.

## Rebuild from Scratch

```bash
./destroy.sh       # remove container, keep volume + image
./up.sh            # recreate from existing image (fast)

# Full rebuild (re-download + rebuild everything):
./destroy.sh --all
./up.sh
```

## Troubleshooting

**`container` CLI not found:**
Install from [github.com/apple/container/releases](https://github.com/apple/container/releases). It's a signed `.pkg` installer.

**Container won't start:**
Check that the container system is running:
```bash
container system start
```

**Shared folder not appearing:**
Ensure `SHARED_FOLDER` is set in `.env` and points to an existing directory before running `./up.sh`. The variable must be set when creating the container (not when starting an existing one).

**npm packages not installed:**
All npm packages are installed via nvm for the `claude` user. To reinstall manually:
```bash
./shell.sh
source ~/.nvm/nvm.sh
npm install -g @anthropic-ai/claude-code claude-flow@alpha playwright
```

**Chromium/Playwright issues:**
This project uses Alpine's native Chromium build instead of Playwright's bundled browser. If Chromium doesn't work:
```bash
./shell.sh
chromium-browser --version    # verify it's installed
echo $PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH   # should be /usr/bin/chromium-browser
```

## Architecture

| Feature | Implementation |
|---|---|
| Hypervisor | Apple Virtualization.framework |
| Container runtime | Apple Containerization framework |
| Base image | Alpine Linux (ARM64, ~5 MB) |
| Isolation | Dedicated lightweight VM per container |
| Shared folders | Bind mount from host |
| Networking | Dedicated IP per container |
| State | Named volume (`claude-home`) for `/home/claude` |
| Shell access | `container exec` (no SSH server needed) |

## How It Works

Apple Containers runs each container in its own dedicated lightweight virtual machine (not namespace-based isolation like Docker on Linux). The `container` CLI manages the lifecycle:

```
./up.sh runs
  → Checks prerequisites (Apple Silicon, container CLI)
  → Builds OCI image from Containerfile (first run only)
  → Creates named volume for /home/claude (first run only)
  → Starts container with volume + shared folder mounts
  → Done — fully configured environment ready to use
```

Unlike Docker Desktop (which runs many containers inside one large Linux VM), each container here gets its own hypervisor-level isolation.

## References

- [Apple container CLI](https://github.com/apple/container)
- [Apple Containerization framework](https://github.com/apple/containerization)
- [Meet Containerization — WWDC25](https://developer.apple.com/videos/play/wwdc2025/346/)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview)
- [claude-flow](https://github.com/ruvnet/claude-flow)
- [Alpine Linux](https://alpinelinux.org/)

## Related Projects

- [claude-qemu-script](https://github.com/icazemier/claude-qemu-script) — same concept using QEMU (cross-platform)
- [claude-vagrant-script](https://github.com/icazemier/claude-vagrant-script) — same concept using Vagrant + VirtualBox

## License

MIT

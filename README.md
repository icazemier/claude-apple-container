# claude-apple-container

A Claude Code development environment running in Apple's native Containerization framework — no Docker Desktop, no QEMU, no VirtualBox.

## What's Included

- **Alpine Linux** (~5 MB base, ARM64)
- **Node.js 24** + npm + yarn (Alpine native packages)
- **Claude Code** (`@anthropic-ai/claude-code`)
- **claude-flow** orchestrator (`claude-flow@alpha`)
- **Playwright** with Chromium (Alpine native build)
- **Native module build deps**: cairo, pango, pixman, libjpeg, giflib, librsvg (for packages like `canvas`)
- **Dev tools**: git, curl, wget, vim, python3, build-base (gcc/make/etc.), openssh-client

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
| `VM_MEMORY` | `8G` | Memory allocated to the container VM |
| `VM_CPUS` | `4` | CPU cores allocated to the container VM |
| `EXTRA_PACKAGES` | _(none)_ | Space-separated Alpine packages, installed on every `./up.sh` |
| `DOTFILES` | _(none)_ | Comma-separated host paths to restore into `/home/claude` on every `./up.sh` |
| `COPY_FOLDERS` | _(none)_ | Comma-separated project folders to copy into `/home/claude` on every `./up.sh` |

Changes take effect after `./stop.sh && ./up.sh`.

**Important:** Memory and CPU are set at container creation time. Changing `VM_MEMORY` or `VM_CPUS` requires `./destroy.sh && ./up.sh` (not just stop/start). Your `/home/claude` data is preserved on the named volume.

## Dotfiles (SSH Keys, Git Config, etc.)

Set `DOTFILES` in `.env` to automatically restore host files into the container on every `./up.sh`:

```
DOTFILES=~/.ssh,~/.gitconfig
```

This copies your SSH keys, git config, and any other files into `/home/claude` — surviving even `destroy --all`. Files are only copied if they don't already exist in the VM, so in-VM customizations are preserved. SSH key permissions are automatically fixed.

You can include any file or directory under `~`:

```
DOTFILES=~/.ssh,~/.gitconfig,~/.npmrc,~/.config/gh
```

## Copy Project Folders

Instead of using `SHARED_FOLDER` (which uses a live virtio-fs mount), you can copy project folders into the container:

```
COPY_FOLDERS=~/Development/EnkProject8,~/Development/AnotherProject
```

This copies each folder into `/home/claude/Development/...` on every `./up.sh` — but only if it doesn't already exist in the VM. `node_modules` are excluded from the copy (they'll be installed fresh on tmpfs via `nm-local`).

This approach works better for Node.js projects since the files live on the volume instead of a live mount, and `node_modules` goes to tmpfs automatically.

Note: this is a **one-way copy**. Changes inside the VM don't sync back to the host. Use `git` to push your work out.

## node_modules on virtio-fs

Apple Containers uses virtio-fs for all filesystems, which can't handle the deeply nested symlink-heavy structure of `node_modules`. The container includes an automatic workaround:

- `yarn` and `npm` commands are wrapped to automatically relocate `node_modules` to a tmpfs (RAM-backed) mount
- This happens transparently — just run `yarn install` as normal
- You can also run `nm-local` manually in any project directory
- Downside: `node_modules` is lost on container restart (just re-run `yarn install`)

## Shared Folder

Set `SHARED_FOLDER` in `.env`:

```
SHARED_FOLDER=/Users/you/myproject
```

The directory appears at `/home/claude/shared` inside the container. Use your host IDE/editor to edit files, let Claude Code in the container handle execution, builds, and tests.

## State Persistence

| What | Survives `stop`/`start`? | Survives `destroy` + `up`? |
|---|---|---|
| Installed packages (`apk add ...`) | Yes | No — use `EXTRA_PACKAGES` instead |
| `EXTRA_PACKAGES` in `.env` | Yes | Yes — reinstalled automatically |
| `/home/claude` (SSH keys, config, history) | Yes | Yes — stored on named volume (`DOTFILES` survives `--all`) |
| `node_modules` | No (tmpfs) | No — re-run `yarn install` |
| Project files in shared folder | Yes | Yes — lives on host |
| Base tooling (Node.js, Claude Code, etc.) | Yes | Yes — part of the image |
| VM memory / CPU settings | Yes | Applied from `.env` on recreate |

## Installing Additional Packages

**Quick install** (persists across `stop`/`start`, lost on `destroy`):

```bash
./shell.sh
sudo apk add htop redis
```

**Persistent install** (survives `destroy` + `up`): add to `EXTRA_PACKAGES` in `.env`:

```bash
EXTRA_PACKAGES=htop redis postgresql-client
```

These are automatically reinstalled every time `./up.sh` runs. You can safely `./destroy.sh && ./up.sh` (e.g. to change memory/CPU) without losing your tools.

**Baked into the image** (for packages everyone needs): add them to the `Containerfile` and rebuild:

```bash
./destroy.sh
./up.sh
```

## Native Node.js Modules

The container includes build dependencies for common native modules like `canvas`, `sharp`, and others that need C/C++ compilation:

| Dependency | Alpine Package | Used By |
|---|---|---|
| Cairo + Pango | `cairo-dev`, `pango-dev` | `canvas`, `pdfjs-dist` |
| Pixman | `pixman-dev` | `canvas` |
| libjpeg | `jpeg-dev` | `canvas`, `sharp` |
| giflib | `giflib-dev` | `canvas` |
| librsvg | `librsvg-dev` | `canvas` (SVG support) |
| GCC/Make | `build-base` | All native modules |
| Python | `python3` | `node-gyp` |

If you encounter a missing native dependency, install it with:

```bash
sudo apk add <package-name>-dev
```

Then add it to the Containerfile to make it permanent.

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

## Resources

The default 8G RAM / 4 CPUs is suitable for Claude Code + Chromium. Apple's own default (1 GiB) is too low and causes OOM kills.

**Disk** does not need pre-allocation — Apple Containers uses sparse files that only consume actual bytes written on your host disk. A "512 GiB" disk might only use a few GB in practice.

To monitor resource usage:

```bash
container stats              # real-time CPU, memory, I/O (like top)
container stats --no-stream  # one-shot snapshot
```

To change resources, edit `.env` and recreate:

```bash
# In .env:
VM_MEMORY=16G
VM_CPUS=8

# Then:
./destroy.sh && ./up.sh      # /home/claude data preserved
```

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
`up.sh` auto-starts the container system, but if you still have issues:
```bash
container system start --enable-kernel-install
```

**Shared folder not appearing:**
Ensure `SHARED_FOLDER` is set in `.env` and points to an existing directory before running `./up.sh`. The variable must be set when creating the container (not when starting an existing one).

**npm packages not installed:**
Global npm packages are installed as root in the Containerfile. To reinstall manually:
```bash
./shell.sh
sudo npm install -g @anthropic-ai/claude-code claude-flow@alpha
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
  → Starts container system + installs kernel (if not running)
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

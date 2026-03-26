# PRD: claude-apple-container

## Overview

A turnkey solution for running Claude Code in an isolated Linux container using Apple's native Containerization framework — no Docker Desktop, no QEMU, no VirtualBox. Follows the same principles as [claude-qemu-script](https://github.com/icazemier/claude-qemu-script) and [claude-vagrant-script](https://github.com/icazemier/claude-vagrant-script), but leverages Apple's first-party container tooling for a lighter, faster, and more native experience on macOS.

## Problem Statement

Running Claude Code in a sandboxed Linux environment currently requires either:

- **QEMU** — manual setup, large Ubuntu image (~600 MB base), ~5 min provisioning
- **Vagrant + VirtualBox** — heavy dependency chain, licensing concerns, large VM footprint

Apple's native Containerization framework (announced WWDC 2025) eliminates the need for third-party virtualization software entirely. Each container runs in its own lightweight VM backed by Apple's Hypervisor.framework, providing hardware-level isolation with sub-second boot times.

## Workflow Comparison

### Current: QEMU / Vagrant (SSH-based)

```bash
./up.sh                        # boot VM (~minutes, Ubuntu 24.04 ~600 MB)
./ssh.sh                       # SSH into VM as claude user
# Full Ubuntu bash session
claude                         # run Claude Code
git clone ...                  # work on projects
apt install ...                # install packages
exit                           # leave SSH session
./stop.sh                      # shut down VM
```

### New: Apple Containers (exec-based)

```bash
./up.sh                        # build + start container (~seconds, Alpine ~5 MB)
./shell.sh                     # container exec as claude user
# Alpine bash session — same feel
claude                         # run Claude Code
git clone ...                  # work on projects
apk add ...                    # install packages
exit                           # leave shell session
./stop.sh                      # stop container
```

**At the keyboard, the experience is identical.** You get a Linux terminal prompt, all your tools are there, and you work as if you're on the machine itself. The difference is under the hood — `container exec` instead of SSH — and the startup is seconds instead of minutes.

### Side-by-Side Comparison

| Aspect | QEMU / Vagrant (SSH) | Apple Container (exec) |
|---|---|---|
| Startup time | ~5 minutes (first), ~30s (subsequent) | ~5 seconds |
| Base image size | ~600 MB (Ubuntu) | ~5 MB (Alpine) |
| Third-party deps | QEMU or VirtualBox + Vagrant | None (Apple native) |
| Shell prompt | Full bash session | Full bash session (same) |
| Interactive programs (vim, claude, node) | Works | Works |
| Multiple sessions | Open another `./ssh.sh` | Open another `./shell.sh` |
| Install packages | `apt install ...` (persists) | `apk add ...` (persists) |
| SSH keys / git config | Persists across reboot | Persists (named volume) |
| Shared folder | Host dir at `/home/claude/shared` | Host dir at `/home/claude/shared` (same) |
| SSH from host tools | Yes (native SSH) | No (v1) — use `container exec` |
| VS Code Remote / JetBrains Gateway | Yes (SSH) | Not in v1 (future enhancement) |
| Copy files in/out | `scp` / shared folder | Shared folder / `container cp` |
| Host SSH agent forwarding | SSH agent forward | `--ssh` flag (automatic) |
| Desktop / VNC | XFCE4 over VNC | Not in v1 (future enhancement) |
| Isolation model | Full VM (QEMU/VirtualBox) | Lightweight VM (Apple Hypervisor) |

### What You Gain

- **Seconds instead of minutes** to a working environment
- **~120x smaller** base image (5 MB vs 600 MB)
- **Zero third-party software** to install and maintain
- **Native macOS integration** via Apple's own framework

### What You Trade Off (v1)

- **No SSH server** — IDE remote extensions (VS Code Remote, JetBrains Gateway) won't connect. Workaround: use the shared folder with your host IDE, or add SSH server as a v2 feature.
- **No desktop/VNC** — CLI only. Planned for v2.
- **Alpine instead of Ubuntu** — different package names (`apk` vs `apt`), musl instead of glibc. Most tools work identically, but some native binaries may need musl-compatible builds.

## Goals

1. **Zero third-party dependencies** — no Docker Desktop, no VirtualBox, no QEMU, no Vagrant. Only Apple's native `container` CLI.
2. **Minimal footprint** — Alpine Linux base image (~5 MB compressed), smallest viable userspace.
3. **Fast startup** — target sub-5-second boot-to-ready (vs. minutes with QEMU/Vagrant).
4. **Same developer experience** — `up.sh` / `stop.sh` / `destroy.sh` / `shell.sh` lifecycle scripts matching existing projects.
5. **Claude Code ready** — Node.js, Claude Code, claude-flow, and Playwright pre-installed.
6. **Shared folder support** — mount host project directory into the container.
7. **Open source** — MIT or Apache 2.0 licensed.

## Base OS Decision: Alpine Linux

### Why Alpine

Alpine Linux is the confirmed base OS for this project. At ~5 MB compressed (ARM64), it is the smallest general-purpose Linux distribution with a real package ecosystem. It uses musl libc + BusyBox — the same minimalist philosophy as Tiny Core Linux — but with native ARM64 support and confirmed Apple Containers compatibility (used in Apple's own examples).

All required packages are available for `aarch64`:
- `nodejs` 22.x, `git`, `openssh`, `build-base`, `chromium`, `python3`, `bash`, `curl`

### Alternatives Evaluated

| Distro | ARM64 Size | Why Not |
|---|---|---|
| Tiny Core Linux | ~11 MB | No ARM64 container images; piCore kernel is RPi-specific |
| Wolfi OS (Chainguard) | ~5.5 MB | No `chromium` apk package; smaller ecosystem |
| Void Linux (musl-busybox) | ~14.4 MB | 3x Alpine; uncertain Node.js 24 availability; less familiar `xbps` |
| Debian Slim | ~28 MB | 5x Alpine; pragmatic but unnecessarily large |
| Chimera Linux | ~50-80 MB | No Node.js 24 LTS; large; untested on Apple Containers |
| Distroless | ~141 MB | No shell or package manager; incompatible with interactive use |
| BusyBox | ~1-2 MB | No package manager; would require rebuilding Alpine from scratch |

### Fallback: Wolfi OS

If musl compatibility becomes a blocker (primarily for Playwright/Chromium), **Wolfi OS** (~5.5 MB, glibc-based) is the designated fallback. Its glibc base means Playwright's official binaries work without workarounds.

### Playwright on Alpine (Known Workaround)

Playwright does not officially support Alpine/musl. The workaround:
1. Install Alpine's native `chromium` package: `apk add chromium`
2. Set `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium-browser`
3. Skip Playwright's bundled browser download: `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`

## Non-Goals

- macOS guest OS (Linux only)
- Intel Mac support (Apple Silicon only)
- Kubernetes/orchestration integration
- GUI/desktop environment (CLI-only for v1; VNC/desktop as future enhancement)
- Production deployment (local development only)
- SSH server inside the container (use `container exec` instead)

## Requirements

### Developer Prerequisites

The developer needs exactly **one tool** installed beyond macOS itself:

| Requirement | Detail |
|---|---|
| Hardware | Apple Silicon (M1/M2/M3/M4) |
| macOS | 15.0 (Sequoia) minimum, 26.0 (Tahoe) for full features |
| Apple `container` CLI | Installed from [GitHub releases](https://github.com/apple/container/releases) (signed `.pkg` installer) |

That's it. No Docker Desktop, no VirtualBox, no Vagrant, no QEMU, no Homebrew dependencies. `up.sh` verifies all prerequisites and gives clear error messages if anything is missing.

### Functional Requirements

#### FR-1: Container Lifecycle Scripts

| Script | Responsibility |
|---|---|
| `up.sh` | Verify prerequisites (Apple Silicon, `container` CLI installed), ensure container system is running (auto-start + kernel install), load `.env`, build image if needed, start the container, print connection info |
| `stop.sh` | Gracefully stop the running container |
| `destroy.sh` | Stop container and remove all associated resources. `--all` flag also removes cached images and named volumes |
| `shell.sh` | Open an interactive shell in the running container via `container exec` |

#### FR-2: Container Image (Containerfile)

Base: `alpine:latest` (ARM64)

Layers:
1. System packages: `nodejs`, `npm`, `yarn`, `git`, `curl`, `build-base`, `chromium`, `python3`, `bash`, `sudo`, `openssh-client`, `vim`, `wget`
2. Global npm packages (as root): `@anthropic-ai/claude-code`, `claude-flow@alpha`
3. User: `claude` with passwordless sudo
4. Playwright config (using Alpine's native `chromium` package)
5. Shell configuration + welcome banner

Note: Node.js is installed via Alpine's native `nodejs` package (not nvm). nvm attempts to compile from source on musl/Alpine which fails. Alpine's package is prebuilt for ARM64.

No SSH server needed — `container exec` provides direct shell access.

#### FR-3: Configuration via `.env`

| Variable | Default | Description |
|---|---|---|
| `SHARED_FOLDER` | _(none)_ | Host directory to mount at `/home/claude/shared` |
| `FORWARDED_PORTS` | _(none)_ | Comma-separated list of TCP ports to forward |
| `CONTAINER_NAME` | `claude-dev` | Name for the container instance |
| `VM_MEMORY` | `8G` | Memory allocated to the container VM (Apple default 1 GiB is too low) |
| `VM_CPUS` | `4` | CPU cores allocated to the container VM |

Note: Memory and CPU are set at container creation time. Changing them requires `destroy` + `up` (not just stop/start). Disk is sparse and does not need configuration.

#### FR-4: Container Access

Primary access is via `container exec` (no SSH required):

```bash
./shell.sh                    # interactive shell as claude user
container exec -it claude-dev sh  # equivalent direct command
```

SSH agent forwarding from the host is available via the `--ssh` flag on `container run`, which automatically mounts the host's `SSH_AUTH_SOCK` into the container.

#### FR-5: State Persistence

| Layer | Mechanism | Survives `stop`/`start`? | Survives `rm`/`run`? |
|---|---|---|---|
| Installed packages (`apk add ...`) | Container filesystem (EXT4) | **Yes** | No — rebuild from Containerfile |
| `/home/claude` (SSH keys, config, shell history) | Named volume `claude-home` | **Yes** | **Yes** — volume is independent |
| Project files | Bind mount from host | **Yes** | **Yes** — lives on host |
| Base tooling (Node.js, Claude Code, etc.) | Baked into Containerfile | **Yes** | **Yes** — part of the image |

A developer can `apk add` packages, generate SSH keys, configure git — all of it persists across `stop`/`start`. The named volume for `/home/claude` ensures personal config survives even `destroy` + recreate.

#### FR-6: Shared Folder

- Host directory bind-mounted into the container at `/home/claude/shared`
- Configured via `SHARED_FOLDER` in `.env`
- Read-write by default

```bash
container run -v ${SHARED_FOLDER}:/home/claude/shared ...
```

#### FR-7: Networking

Each container gets its own dedicated IP address (e.g., `192.168.64.3`). Services inside the container are directly reachable from the host without port mapping.

Port forwarding is available for explicit mappings:
```bash
container run -p 127.0.0.1:8080:8000 ...
```

Host services are reachable from inside the container via:
```bash
sudo container system dns create host.container.internal --localhost
```

Note: Full container-to-container networking requires macOS 26 (Tahoe).

#### FR-8: Provisioning

The Containerfile bakes in the full environment. No separate `provision.sh` needed:

- `claude` user with passwordless sudo
- Node.js 24 (Alpine native package, not nvm)
- Claude Code (`@anthropic-ai/claude-code`)
- claude-flow (`claude-flow@alpha`)
- Playwright + Chromium (Alpine native package)
- Git, vim, curl, wget, build-base, python3
- SSH agent auto-start in `.bashrc`
- Host SSH agent forwarding (via `--ssh` flag)
- Welcome banner with auth instructions
- Container stays alive via `sleep infinity` (shell access via `container exec`)

## Developer Experience

### Quick Start

```bash
# 1. Install Apple container CLI (one-time, from GitHub releases .pkg)
# 2. Clone and configure
git clone <repo-url> && cd claude-apple-container
cp .env.example .env
# Edit .env to set SHARED_FOLDER if needed

# 3. Start
./up.sh          # builds image on first run, starts container

# 4. Use
./shell.sh       # interactive shell as claude user
# Inside: claude, node, git, etc. are all ready

# 5. Lifecycle
./stop.sh        # stop (state preserved)
./up.sh          # start again (everything still there)
./destroy.sh     # remove container (named volume preserved)
./destroy.sh --all  # remove everything including volumes and images
```

### Installing Additional Packages

```bash
./shell.sh
apk add python3 redis    # persists across stop/start
```

Packages installed via `apk add` persist across `stop`/`start` cycles. They are only lost on `destroy` + recreate (in which case, consider adding them to the Containerfile instead).

### Personal Config Persistence

SSH keys, git config, shell history, and any files in `/home/claude` are stored on a named volume (`claude-home`) that persists even across `destroy` + recreate. Only `destroy --all` removes it.

## Architecture

```
Host (macOS, Apple Silicon)
 |
 |-- container CLI (/usr/local/bin/container)
 |     |
 |     |-- Apple Containerization framework
 |           |
 |           |-- Virtualization.framework
 |           |     |
 |           |     |-- Lightweight VM (one per container)
 |           |           |
 |           |           |-- vminitd (minimal init)
 |           |           |-- Alpine Linux userspace
 |           |           |-- claude user environment
 |           |           |-- Named volume: claude-home (/home/claude)
 |           |
 |           |-- OCI Image (built from Containerfile)
 |           |-- Bind mount: host project dir <-> /home/claude/shared
 |
 |-- up.sh / stop.sh / destroy.sh / shell.sh
 |-- .env (user configuration)
```

### Key Architectural Difference

Unlike Docker Desktop (which runs many containers inside one large Linux VM), Apple Containers runs **each container in its own dedicated lightweight VM**. This provides hypervisor-level isolation per container rather than namespace-based isolation.

## Project Structure

```
claude-apple-container/
├── PRD.md                # This document
├── README.md             # User-facing documentation
├── .env.example          # Configuration template
├── .gitignore            # .env, etc.
├── Containerfile         # Alpine-based OCI image definition
├── up.sh                 # Build image (if needed), start container
├── stop.sh               # Stop the container
├── destroy.sh            # Remove container and resources
└── shell.sh              # Open interactive shell via container exec
```

## Resolved Questions

| # | Question | Resolution |
|---|---|---|
| 1 | Is `container` CLI available via Homebrew? | No — signed `.pkg` installer from GitHub releases only |
| 2 | Does nvm work on Alpine? | No — nvm tries to compile Node.js from source on musl, fails. Use Alpine's native `nodejs` package instead |
| 3 | Does the container stay alive in detached mode? | `bash -l` exits immediately. Use `sleep infinity` as CMD, access via `container exec` |
| 4 | Does `container system start` need manual setup? | Yes — requires kernel install on first run. `up.sh` handles this with `--enable-kernel-install` flag |
| 5 | What is the `container run` flag syntax for memory/CPU limits? | `-m 8G` and `-c 4`. Apple default is 1 GiB which OOM-kills Claude Code. We default to 8G/4 CPUs. Memory/CPU are set at creation time only — changing requires destroy + recreate |
| 6 | Does disk need pre-allocation? | No — Apple Containers uses sparse EXT4 files (~512 GiB apparent, only actual bytes on host disk). No `--disk-size` flag exists |

## Open Questions

| # | Question | Impact |
|---|---|---|
| 1 | Does the Playwright + Alpine chromium workaround function correctly on ARM64 in Apple Containers? | May require fallback to Wolfi OS |

## Caveats

- **No `container restart` command** — `stop.sh` + `up.sh` is the workaround
- **macOS 26 (Tahoe) required** for full container-to-container networking; macOS 15 supports basic container-to-host and port forwarding
- **Framework is v0.10.0** — still maturing; earlier versions had stop/start bugs with volumes (fixed in v0.4.1)
- **Image unpacking can be slow** — large images may take minutes to unpack (Apple's custom Swift EXT4 implementation is being optimized)
- **nvm does not work on Alpine** — it attempts to compile Node.js from source against musl libc, which fails. Use Alpine's native `nodejs` package instead
- **npm install -g requires root** — global packages must be installed before `USER` switch in Containerfile, or with `sudo`
- **Builder disk space** — the builder VM has limited disk; large images (Chromium + Claude Code) can exhaust it. Free host disk space or `container builder rm` to reset
- **Memory/CPU require recreate** — these are set at container creation time. Changing `VM_MEMORY` or `VM_CPUS` requires `destroy` + `up` (named volume preserves `/home/claude` data)

## Future Enhancements (v2+)

- XFCE4 desktop environment with VNC access (matching QEMU/Vagrant projects)
- Optional SSH server for VS Code Remote / JetBrains Gateway access
- `docker-compose`-like multi-container setup (e.g., Claude + database)
- Automatic `container` CLI installation in `up.sh`
- Integration with claude-flow for multi-agent orchestration across multiple containers
- Wolfi OS variant if musl proves problematic
- `container export` to snapshot a configured environment as a reusable image

## References

- [Apple container CLI](https://github.com/apple/container)
- [Apple Containerization framework](https://github.com/apple/containerization)
- [Meet Containerization — WWDC25 Session 346](https://developer.apple.com/videos/play/wwdc2025/346/)
- [claude-qemu-script](https://github.com/icazemier/claude-qemu-script)
- [claude-vagrant-script](https://github.com/icazemier/claude-vagrant-script)
- [Alpine Linux](https://alpinelinux.org/)

# Agent Dev Space

Persistent cloud VM for AI-assisted development. Provision a Hetzner server with Claude Code pre-installed, SSH in,
start coding in tmux, close your laptop — come back later and your session is still running.

## Status

**Stage 1 — Working.** Single-user, private workspace. Provisioning, SSH access, Claude Code, persistent tmux sessions.

## Quick Start

**Prerequisites:** Hetzner Cloud account, SSH key, [Task](https://taskfile.dev) installed.

```bash
# Configure
cp .env.example .env
# Edit .env — set HETZNER_API_TOKEN

# Provision
task provision

# Connect and start coding
task claude          # opens tmux + Claude Code
                     # authenticate Claude on first run

# Close laptop, go to sleep...

# Next day
task attach          # session is still there
```

## Commands

| Command          | Description                                     |
|------------------|-------------------------------------------------|
| `task provision` | Provision a new Hetzner VM                      |
| `task destroy`   | Destroy the VM (with confirmation)              |
| `task ssh`       | SSH into the VM                                 |
| `task claude`    | Start/attach Claude Code in tmux                |
| `task attach`    | Attach to existing tmux session                 |
| `task status`    | VM health: uptime, disk, memory, tmux sessions  |
| `task ip`        | Print VM IP address                             |
| `task setup`     | Re-run setup script on existing VM (idempotent) |

## Configuration

`.env` file (see `.env.example`):

| Variable              | Required | Default                 | Description                   |
|-----------------------|----------|-------------------------|-------------------------------|
| `HETZNER_API_TOKEN`   | Yes      | —                       | Hetzner Cloud API token       |
| `SSH_PUBLIC_KEY_PATH` | No       | `~/.ssh/id_ed25519.pub` | SSH public key to deploy      |
| `HETZNER_SERVER_TYPE` | No       | `cx23`                  | VM size (cx23/cx33/cx43/cx53) |
| `HETZNER_REGION`      | No       | `nbg1`                  | Datacenter (nbg1/fsn1/hel1)   |

**Server types:** cx23 (2vCPU/4GB ~€3/mo), cx33 (4vCPU/8GB ~€5/mo), cx43 (8vCPU/16GB ~€9/mo), cx53 (16vCPU/32GB ~€17/mo)

## What's on the VM

- Ubuntu 24.04 LTS
- Claude Code (latest)
- Node.js LTS
- tmux (50K line history, mouse support)
- git, curl, wget, build-essential, jq, htop
- SSH hardened: key-only auth, no root login

## Architecture (Stage 1)

```
Local machine ──SSH──▶ Hetzner VM (Ubuntu 24.04)
                       ├── tmux (persistent sessions)
                       └── Claude Code
```

## Roadmap

- **Stage 2** — VS Code Remote Tunnel, Docker, firewall, snapshot-based provisioning
- **Stage 3** — Telegram bot for messenger-based agent control
- **Stage 4** — Multi-agent support (Codex, OpenCode, Aider), browser automation via Playwright MCP + noVNC
- **Stage 5** — Product: auth, billing, dashboard, $19/mo pricing
- **Stage 6** — Teams, Slack, background agents, SSO, EU data residency

See [REQUIREMENTS.md](REQUIREMENTS.md) for full specification.

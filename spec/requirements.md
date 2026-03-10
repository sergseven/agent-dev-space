# Agent Dev Space — Requirements Specification

> Persistent cloud-hosted AI engineering workspace.

---

## Problem Statement

Developers using AI coding agents face a fundamental constraint: **agents die when the laptop closes**. Existing
workarounds:

- **Leave laptop on** — unreliable, wastes power
- **DIY VPS + tmux** — works but requires manual setup every time, no standardization
- **Claude Code on the Web** — GitHub-only, ephemeral, no custom MCP servers, no persistent environment
- **Claude Code Remote Control** — laptop must stay on and connected

**The gap**: No product ships a persistent cloud workspace where a developer runs a provisioning script, gets a VM with
Claude Code ready, and the session keeps working when their laptop is off.

---

## Stage 1 — Private Agent-First Dev Workspace (Prove It Works)

**Goal**: A single developer (you) can provision a remote VM, SSH in, run Claude Code in a persistent session, close the
laptop, and come back later to find the session still running.

**No product, no users, no billing.** Just prove the core loop works.

### Requirements

| ID        | Requirement               | Detail                                                                                                                                                               |
|-----------|---------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **S1-01** | Automated VM provisioning | A single script provisions a Hetzner Cloud VM (Ubuntu 24.04 LTS) with all dependencies installed. Run once, get a working machine.                                   |
| **S1-02** | Hetzner as VM provider    | Interactive server type selection from available options (see Server Types below). Hetzner Cloud API. Region: Nuremberg or Falkenstein. |
| **S1-03** | Remote terminal access    | SSH into the VM from local machine. Key-based auth only.                                                                                                             |
| **S1-04** | Claude Code pre-installed | Claude Code installed and ready to use on the VM. User provides their own Anthropic API key via `.env` file before provisioning. Key is deployed to the VM during setup. |
| **S1-05** | Persistent session        | Claude Code runs inside tmux. SSH disconnect or laptop shutdown does NOT kill the session. User reconnects via SSH + `tmux attach` and picks up where they left off. |

### Server type selection

The provisioning script interactively prompts for server type:

```
Select server type:
  1) CX22  — 2 vCPU,  4GB RAM,  40GB SSD — ~€4/mo
  2) CX32  — 4 vCPU,  8GB RAM,  80GB SSD — ~€8/mo
  3) CX42  — 8 vCPU, 16GB RAM, 160GB SSD — ~€16/mo
  4) CX52  — 16 vCPU, 32GB RAM, 320GB SSD — ~€31/mo
>
```

Default: CX22 (sufficient for single Claude Code session). CX32 recommended if running Docker workloads alongside agents.

### What gets installed on the VM

All packages installed at **latest stable version** at provision time:

- Ubuntu 24.04 LTS (base image)
- tmux (latest via apt)
- Node.js LTS (latest LTS via nodesource or nvm)
- Claude Code (latest via `npm install -g @anthropic-ai/claude-code`)
- git, curl, wget, build-essential, jq (basic dev tools, latest via apt)
- SSH hardened: key-only auth, no root login

**Nothing else.** No Docker, no Caddy, no noVNC, no Telegram bot, no VS Code tunnel.

### Configuration via `.env`

The project ships with `.env.example`. User copies to `.env` and fills in values before running `provision.sh`.

```bash
# .env.example

# Required: Hetzner Cloud API token
HETZNER_API_TOKEN=

# Required: Anthropic API key (deployed to VM as ANTHROPIC_API_KEY)
ANTHROPIC_API_KEY=

# Optional: SSH public key path (default: ~/.ssh/id_ed25519.pub)
SSH_PUBLIC_KEY_PATH=~/.ssh/id_ed25519.pub

# Optional: Hetzner server type (default: cx22)
HETZNER_SERVER_TYPE=cx22

# Optional: Hetzner datacenter region (default: nbg1 — Nuremberg)
HETZNER_REGION=nbg1
```

The provisioning script:
- Reads `.env` (fails if missing required values)
- If `HETZNER_SERVER_TYPE` is not set, prompts interactively
- Deploys `ANTHROPIC_API_KEY` to the VM's `~/.bashrc` as an export
- Never commits `.env` (listed in `.gitignore`)

### Provisioning script behavior

```
./provision.sh
  1. Reads .env (validates required values present)
  2. Prompts for server type if not set in .env
  3. Creates a Hetzner server via API
  4. Waits for server to be ready
  5. Copies SSH public key for access
  6. Runs setup script on the VM (installs Node.js, tmux, Claude Code, hardens SSH)
  7. Deploys ANTHROPIC_API_KEY to VM environment
  8. Prints: SSH connection string, server IP
  Done.
```

**Idempotent**: Running the setup script again on the same VM doesn't break anything.

### How the user works with it

```
# Provision (one time)
cp .env.example .env
# Edit .env — set HETZNER_API_TOKEN and ANTHROPIC_API_KEY
./provision.sh

# Connect
ssh agentbox@<ip>

# Start Claude Code in tmux (first time)
tmux new-session -s claude
claude

# ... work with Claude Code ...
# Close laptop. Go to sleep.

# Next day — reconnect
ssh agentbox@<ip>
tmux attach -t claude
# Session is still there, Claude Code still running
```

### Success criteria

- [ ] Script provisions VM in < 5 minutes
- [ ] SSH works immediately after provisioning
- [ ] Claude Code starts and responds to prompts
- [ ] Close SSH → reopen SSH → `tmux attach` → session intact with full history
- [ ] Close laptop for 1 hour → reconnect → session intact

---

## Stage 2 — Multi-Access & Polish

**Unlocked by**: Stage 1 works reliably for daily use.

| ID        | Requirement                                                                                                 | Priority |
|-----------|-------------------------------------------------------------------------------------------------------------|----------|
| **S2-01** | VS Code Remote Tunnel — connect local VS Code to remote VM files, run terminal and extensions on VM         | 1        |
| **S2-02** | Multiple named tmux sessions: `claude`, `shell` (general purpose)                                           | 2        |
| **S2-03** | Snapshot-based provisioning — pre-bake a Hetzner snapshot with all software for faster (~2 min) VM creation | 4        |
| **S2-04** | Basic firewall — only ports 22 (SSH) open, fail2ban installed                                               | 1        |
| **S2-05** | Docker + Docker Compose pre-installed — for running user workloads                                          | 3        |
| **S2-06** | Dotfiles support — user can point to a dotfiles repo that gets cloned on provision                          | 4        |

---

## Stage 3 — Messenger Control

**Unlocked by**: Stage 2 works, daily-driving the VM, want mobile/async control.

| ID        | Requirement                                                                         | Priority |
|-----------|-------------------------------------------------------------------------------------|----------|
| **S3-01** | Telegram bot that relays messages to Claude Code on the VM via `claude -p --resume` | 1        |
| **S3-02** | Session continuity — conversation context persists across Telegram messages         | 1        |
| **S3-03** | Bot commands: `/status` (VM health), `/new` (new Claude session), `/screenshot`     | 3        |
| **S3-04** | Long-running tasks: bot acknowledges immediately, posts result when done            | 2        |
| **S3-05** | Rich responses: code blocks, diffs, images                                          | 4        |

---

## Stage 4 — Multi-Agent & Browser

**Unlocked by**: Stage 3 validated, want to expand capabilities.

| ID        | Requirement                                                             | Priority |
|-----------|-------------------------------------------------------------------------|----------|
| **S4-01** | Additional agents: Codex CLI, OpenCode, Aider — user picks which to use | 3        |
| **S4-02** | Playwright MCP + Chromium in Docker — Claude can control a browser      | 1        |
| **S4-03** | noVNC — user can observe/interact with the remote browser via web       | 2        |
| **S4-04** | Per-user subdomain with HTTPS (Caddy): `{user}.agent-dev-space.dev`            | 5        |
| **S4-05** | MCP servers pre-installed: memory server, GitHub, filesystem            | 3        |

---

## Stage 5 — Product (If Validated)

**Unlocked by**: Using it daily, others want it too.

| ID        | Requirement                                               | Priority |
|-----------|-----------------------------------------------------------|----------|
| **S5-01** | Landing page + signup flow                                | 1        |
| **S5-02** | Auth: GitHub/Google OAuth                                 | 1        |
| **S5-03** | Stripe payment → auto-provisions VM                       | 1        |
| **S5-04** | User dashboard: VM status, restart, storage usage         | 3        |
| **S5-05** | API key onboarding wizard (keys stored only on user's VM) | 3        |
| **S5-06** | Pricing: $19/mo Solo tier                                 | 1        |

---

## Stage 6 — Scale & Enterprise

**Unlocked by**: 20+ paying users, inbound from teams.

| ID        | Requirement                                                                 | Priority |
|-----------|-----------------------------------------------------------------------------|----------|
| **S6-01** | Slack integration alongside Telegram                                        | 4        |
| **S6-02** | Background agent mode — assign GitHub/Jira ticket, agent works autonomously | 5        |
| **S6-03** | Scheduled agents — cron-style tasks                                         | 3        |
| **S6-04** | Team workspaces: one admin, multiple VMs, shared billing                    | 5        |
| **S6-05** | Audit log: what the agent did, what commands ran                            | 3        |
| **S6-06** | SSO (SAML/OIDC)                                                             | 5        |
| **S6-07** | EU data residency option (Hetzner region selection)                         | 2        |
| **S6-08** | Pro tier: $39/mo                                                            | 1        |

---

## Architecture (Evolves Per Stage)

### Stage 1 (minimal)

```
Local machine ──SSH──▶ Hetzner VM
                       ├── tmux
                       └── Claude Code
```

### Stage 3 (messenger)

```
Local machine ──SSH──▶ Hetzner VM
Telegram ─────────────▶ ├── Telegram bot service
                        ├── tmux
                        └── Claude Code
```

### Stage 5 (product)

```
┌─────────────────────┐
│  Control Plane       │
│  Auth, Billing, DNS  │
└──────────┬──────────┘
           │ Hetzner API
    ┌──────┼──────┐
    ▼      ▼      ▼
  VM A   VM B   VM C
  (each: Claude Code, tmux, Telegram bot, noVNC, Caddy)
```

---

## Key Decisions

| Decision            | Choice                        | Rationale                                                     |
|---------------------|-------------------------------|---------------------------------------------------------------|
| VM provider         | Hetzner                       | Cheapest EU provider with good API. ~€4/mo per VM.            |
| Session persistence | tmux                          | Battle-tested. No custom daemon needed.                       |
| Provisioning        | Shell script + Hetzner API    | Simplest thing that works. No Terraform overhead for Stage 1. |
| Agent               | Claude Code only (Stage 1)    | Focus. Add others when the base works.                        |
| Auth to VM          | SSH key                       | Standard, secure, zero custom infra.                          |
| API key management  | Via `.env` file, deployed to VM | Keys in `.env` locally, exported to VM's `~/.bashrc`. Never committed to git. |

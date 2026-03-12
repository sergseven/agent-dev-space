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

## Stage 1 — Private Agent-First Dev Workspace ✅ COMPLETE

**Goal**: A single developer (you) can provision a remote VM, SSH in, run Claude Code in a persistent session, close the
laptop, and come back later to find the session still running.

All Stage 1 requirements are implemented and working.

| ID        | Requirement                   | Status |
|-----------|-------------------------------|--------|
| **S1-01** | Automated VM provisioning     | ✅ `provision.sh` — Hetzner Cloud VM (Ubuntu 24.04 LTS) |
| **S1-02** | Hetzner as VM provider        | ✅ Interactive server type selection (CX22–CX52), `.env` config |
| **S1-03** | Remote terminal access        | ✅ SSH key-based auth, no root login |
| **S1-04** | Claude Code pre-installed     | ✅ Via `npm install -g @anthropic-ai/claude-code` |
| **S1-05** | Persistent session            | ✅ tmux — survives SSH disconnect and laptop shutdown |
| **S1-06** | Local config sync             | ✅ `sync-config.sh` — syncs `.gitconfig`, `.ssh/`, `.claude/` |
| **S1-07** | Unified connection via tmux   | ✅ `task connect` — SSH + tmux attach, agent forwarding |
| **S1-08** | Path rewriting on config sync | ✅ Rewrites absolute home paths to `/home/agentbox` |

### How the user works with it

```
# Provision (one time)
cp .env.example .env       # set HETZNER_API_TOKEN
./provision.sh

# Connect (opens interactive TUI session selector)
task connect

# ... work with Claude Code ...
# Close laptop. Go to sleep.

# Next day — reconnect
task connect
# Session is still there, Claude Code still running
```

---

## Stage 2 — Multi-Access & Polish

**Unlocked by**: Stage 1 works reliably for daily use.

| ID        | Requirement                                                                                                 | Priority |
|-----------|-------------------------------------------------------------------------------------------------------------|----------|
| **S2-01** | IDE Remote Access — VS Code tunnel + JetBrains Gateway SSH for full IDE experience on VM                    | 1        |
| **S2-02** | ✅ Multiple named tmux sessions — create/manage via TUI connector (S2-08)                                    | done     |
| **S2-03** | Snapshot-based provisioning — pre-bake a Hetzner snapshot with all software for faster (~2 min) VM creation | 4        |
| **S2-04** | ✅ Basic firewall — ufw (port 22 only), fail2ban (SSH brute-force protection)                                | done     |
| **S2-05** | Docker + Docker Compose pre-installed — for running user workloads                                          | 3        |
| **S2-06** | Dotfiles support — user can point to a dotfiles repo that gets cloned on provision                          | 4        |
| **S2-07** | Multi-provider support — pluggable provisioning backend (see Provider Abstraction below)                    | 1        |
| **S2-08** | ✅ Interactive tmux session connector — TUI to list, select, or create tmux sessions via `task connect`      | done     |
| **S2-09** | ✅ Dev tools pre-installed — `gh` (GitHub CLI), `python3`, `pip`, `python3-venv`                              | done     |

### S2-08: Interactive tmux session connector

**Goal**: `task connect` opens a professional TUI that lists all tmux sessions on the VM with status (attached/detached, window count, creation time), lets the user navigate with arrow keys or vim bindings, and either attach to an existing session or create a new named one.

**Behavior**:

```
  ╔══════════════════════════════════════════╗
  ║       Agent Dev Space · Connect         ║
  ╚══════════════════════════════════════════╝

  Server: 49.13.x.x

  Sessions:

   ▸ claude  ● attached
      2 window(s) · created Mar 12 14:30

     shell  ○ detached
      1 window(s) · created Mar 12 15:00

   + New session

  ↑/↓ navigate · enter select · q quit
```

**Features**:
- Arrow keys and j/k vim navigation
- Highlighted selection row
- Attached/detached status badges
- Session creation with custom name (defaults to `claude`)
- Input validation for session names (alphanumeric, dash, underscore, dot)
- Connectivity check before rendering
- Clean terminal restore on exit

### S2-01: IDE Remote Access

**Goal**: Developers can use their full local IDE (VS Code or JetBrains) connected to the remote VM — edit files, run terminals, use extensions/plugins, all on remote compute.

**Two approaches, both supported**:

#### VS Code Remote Tunnel

Uses the standalone `code` CLI on the VM to create a dev tunnel. No open ports beyond SSH.

**Setup** (automated in `setup-vm.sh`):
- Installs VS Code standalone CLI to `/usr/local/bin/code`
- Downloaded from official Microsoft CDN (Alpine static binary, works on any Linux)

**Usage**:
```bash
task tunnel:code        # starts tunnel, prints auth URL
```

First run requires GitHub/Microsoft authentication via browser URL. After that, the tunnel appears in VS Code desktop under "Remote Explorer → Tunnels".

**What works over tunnel**:
- Full file editing with IntelliSense
- Integrated terminal (runs on VM)
- Extensions execute on VM (Copilot, linters, formatters)
- Port forwarding (preview web apps locally)
- Git operations use VM's SSH agent

#### JetBrains Gateway (SSH)

JetBrains Gateway connects over SSH and auto-installs the IDE backend on the VM. Zero additional setup required on the VM side — SSH access (already configured in S1-03) is sufficient.

**Usage**:
```bash
task tunnel:jb          # prints connection instructions
```

**Steps in Gateway**:
1. Open JetBrains Gateway → SSH → New Connection
2. Enter VM IP (`task ip`), user `agentbox`, key-based auth
3. Select IDE (IntelliJ IDEA, PyCharm, GoLand, WebStorm, etc.)
4. Choose project directory on VM
5. Gateway downloads and starts the IDE backend automatically

**What works over Gateway**:
- Full IDE experience (refactoring, debugging, run configs)
- Terminal runs on VM
- Plugins execute on VM
- SSH agent forwarding for Git operations

#### Taskfile commands

| Task | Description |
|------|-------------|
| `task tunnel:code` | Start VS Code dev tunnel on VM |
| `task tunnel:jb` | Print JetBrains Gateway connection instructions |

### S2-07: Provider Abstraction

**Goal**: Provision the same workspace on different infrastructure. User sets `PROVIDER=xxx` and a token in `.env`, runs
`task provision`, gets the same result regardless of backend.

**Provider contract** — every provider must deliver:

- An SSH-accessible machine (IP or hostname)
- Ubuntu 24.04 or compatible
- Ability to run the same `setup-vm.sh` script
- Persistent storage that survives reboots
- A way to destroy the workspace

#### Provider A: Direct Cloud VMs (simple)

API token → VM. Same model as current Hetzner, different API.

| Provider               | .env config                                                | How it works                             |
|------------------------|------------------------------------------------------------|------------------------------------------|
| **Hetzner** (current)  | `HETZNER_API_TOKEN`                                        | Hetzner Cloud API → CX-series VM         |
| **AWS EC2**            | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` | EC2 API → t3.micro/small/medium instance |
| **GCP Compute Engine** | `GCP_PROJECT_ID`, `GCP_SERVICE_ACCOUNT_KEY_PATH`           | GCE API → e2-micro/small/medium instance |
| **DigitalOcean**       | `DO_API_TOKEN`                                             | DO API → Basic droplet                   |

Each provider is a script in `providers/` (e.g. `providers/hetzner.sh`, `providers/aws.sh`) that implements:

```bash
provider_create    # → sets SERVER_IP, SERVER_ID
provider_wait      # → blocks until SSH is ready
provider_destroy   # → deletes the resource
```

`provision.sh` calls these functions instead of Hetzner API directly.

#### Provider B: Kubernetes Pod-as-Workspace

User has an existing K8s cluster. The workspace is a persistent pod with SSH access.

| .env config         | Description                                              |
|---------------------|----------------------------------------------------------|
| `KUBECONFIG_PATH`   | Path to kubeconfig (or uses default `~/.kube/config`)    |
| `K8S_NAMESPACE`     | Namespace for workspace pod (default: `agent-dev-space`) |
| `K8S_STORAGE_CLASS` | Storage class for PVC (default: cluster default)         |
| `K8S_NODE_SELECTOR` | Optional node selector (e.g. for GPU nodes)              |

**How it works**:

1. Creates a namespace (if not exists)
2. Creates a PersistentVolumeClaim (10–100GB, persists `/home/agentbox`)
3. Deploys a pod: Ubuntu 24.04 image, PVC mounted, SSH server running
4. Exposes SSH via LoadBalancer Service or NodePort
5. Runs `setup-vm.sh` inside the pod via `kubectl exec`
6. Returns the external IP/port for SSH access

**Pod spec essentials**:

- Base image: Ubuntu 24.04 with sshd
- Resources: configurable CPU/memory requests (maps to server type selection)
- PVC: mounted at `/home/agentbox` for persistence across pod restarts
- Liveness probe: sshd process
- No restart limit: pod should always restart

**Why K8s matters**: Companies with existing GKE/EKS clusters can run workspaces on their own infra without giving API
tokens to a third-party service. Code never leaves their cloud account.

#### .env changes

```bash
# Provider selection (default: hetzner)
PROVIDER=hetzner    # options: hetzner, aws, gcp, digitalocean, kubernetes
```

Provider-specific variables are only required when that provider is selected.

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
| API key management  | Interactive auth on first run  | User authenticates Claude Code on the VM. No API keys in provisioning config.  |

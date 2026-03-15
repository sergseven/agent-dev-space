#!/usr/bin/env bash
#
# setup-vm.sh — Runs on the Hetzner VM as root.
# Installs Node.js LTS, tmux, Claude Code, Docker, dev tools. Hardens SSH. Creates agentbox user.
#
set -euo pipefail

LOG_PREFIX="[setup-vm]"
log()  { echo "$LOG_PREFIX $1"; }
err()  { echo "$LOG_PREFIX ERROR: $1" >&2; }

# --- Wait for any existing apt locks (e.g. unattended-upgrades after reboot) ---
log "Waiting for apt locks..."
while fuser /var/lib/dpkg/lock-frontend &>/dev/null; do
  sleep 2
done

# --- System update ---
log "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

# --- Dev tools ---
log "Installing dev tools..."
apt-get install -y -qq \
  git \
  curl \
  wget \
  build-essential \
  jq \
  tmux \
  unzip \
  htop \
  python3 \
  python3-pip \
  python3-venv \
  socat

# --- GitHub CLI ---
log "Installing GitHub CLI..."
if ! command -v gh &>/dev/null; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -qq
  apt-get install -y -qq gh
fi
log "GitHub CLI: $(gh --version | head -1)"

# --- Node.js LTS via nodesource ---
log "Installing Node.js LTS..."
if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
  apt-get install -y -qq nodejs
fi

NODE_VERSION="$(node --version)"
NPM_VERSION="$(npm --version)"
log "Node.js $NODE_VERSION, npm $NPM_VERSION"

# --- Claude Code ---
log "Installing Claude Code..."
npm install -g @anthropic-ai/claude-code
CLAUDE_VERSION="$(claude --version 2>/dev/null || echo 'installed')"
log "Claude Code: $CLAUDE_VERSION"

# --- VS Code CLI (for Remote Tunnels) ---
log "Installing VS Code CLI..."
if ! command -v code &>/dev/null; then
  curl -fsSL "https://code.visualstudio.com/sha/download?build=stable&os=cli-alpine-x64" -o /tmp/vscode-cli.tar.gz
  tar -xzf /tmp/vscode-cli.tar.gz -C /usr/local/bin
  rm -f /tmp/vscode-cli.tar.gz
fi
log "VS Code CLI: $(code version 2>/dev/null | head -1 || echo 'installed')"

# --- Docker Engine ---
log "Installing Docker Engine..."
if ! command -v docker &>/dev/null; then
  apt-get install -y -qq ca-certificates gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable docker
systemctl is-active --quiet docker || systemctl start docker
log "Docker: $(docker --version)"
log "Compose: $(docker compose version)"

# --- Build workspace Docker image (if build context was provided) ---
if [[ -d /tmp/docker-workspace ]]; then
  log "Building workspace Docker image..."
  docker build -t agent-dev-space:latest /tmp/docker-workspace
  rm -rf /tmp/docker-workspace
  log "Workspace image: $(docker images agent-dev-space:latest --format '{{.Size}}')"
fi

# --- Create agentbox user ---
log "Creating agentbox user..."
if ! id -u agentbox &>/dev/null; then
  useradd -m -s /bin/bash -G sudo,docker agentbox
  # Allow sudo without password for agentbox
  echo "agentbox ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agentbox
fi
usermod -aG docker agentbox

# --- SSH key for agentbox user ---
log "Setting up SSH key for agentbox user..."
AGENTBOX_HOME="/home/agentbox"
mkdir -p "$AGENTBOX_HOME/.ssh"

# Copy root's authorized keys to agentbox — fail if missing
if [[ ! -f /root/.ssh/authorized_keys ]]; then
  err "No authorized_keys found for root. Cannot set up agentbox SSH access."
  err "Aborting BEFORE hardening SSH to avoid lockout."
  exit 1
fi

cp /root/.ssh/authorized_keys "$AGENTBOX_HOME/.ssh/authorized_keys"

chown -R agentbox:agentbox "$AGENTBOX_HOME/.ssh"
chmod 700 "$AGENTBOX_HOME/.ssh"
chmod 600 "$AGENTBOX_HOME/.ssh/authorized_keys"

# Verify agentbox can be reached before we disable root
log "Verifying agentbox SSH access..."
if ! su - agentbox -c "echo 'agentbox ssh ok'" &>/dev/null; then
  err "agentbox user verification failed. Aborting before SSH hardening."
  exit 1
fi

# --- Workspace config directory (shared mounts for containers) ---
log "Setting up workspace config directories..."
mkdir -p "$AGENTBOX_HOME/.config/workspace/.ssh"
mkdir -p "$AGENTBOX_HOME/.ssh-agent"
touch "$AGENTBOX_HOME/.config/workspace/.gitconfig"
chown -R agentbox:agentbox "$AGENTBOX_HOME/.config" "$AGENTBOX_HOME/.ssh-agent"

# --- Harden SSH ---
log "Hardening SSH..."
SSHD_CONFIG="/etc/ssh/sshd_config"

# Disable password auth (keep UsePAM yes — required for key auth on Ubuntu 24.04)
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' "$SSHD_CONFIG"

# Disable root login
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"

# Validate config before restarting
if ! sshd -t; then
  err "SSH config validation failed. Skipping SSH restart to avoid lockout."
  exit 1
fi

# Restart SSH (Ubuntu 24.04 uses ssh.service, not sshd.service)
systemctl restart ssh

# --- Firewall (ufw) ---
log "Configuring firewall..."
apt-get install -y -qq ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw --force enable

# --- fail2ban ---
log "Configuring fail2ban..."
apt-get install -y -qq fail2ban
cat > /etc/fail2ban/jail.local <<'JAIL'
[sshd]
enabled = true
port = 22
maxretry = 5
bantime = 600
findtime = 600
JAIL
systemctl enable fail2ban
systemctl restart fail2ban

# --- tmux config for agentbox ---
log "Setting up tmux config..."
cat > "$AGENTBOX_HOME/.tmux.conf" <<'TMUX'
# Keep plenty of history
set -g history-limit 50000

# Enable mouse support
set -g mouse on

# Start windows and panes at 1
set -g base-index 1
setw -g pane-base-index 1

# Status bar
set -g status-style 'bg=#333333 fg=#ffffff'
set -g status-left '[ads] '
set -g status-right '%H:%M '

# Don't auto-rename windows
set -g allow-rename off

# Update SSH_AUTH_SOCK in existing panes when reattaching
# This ensures agent forwarding works after SSH reconnect
set -g update-environment "SSH_AUTH_SOCK SSH_CONNECTION DISPLAY"
TMUX

chown agentbox:agentbox "$AGENTBOX_HOME/.tmux.conf"

# --- SSH agent forwarding for tmux + containers ---
# Uses socat to proxy the SSH agent socket to a fixed path (~/.ssh-agent/agent.sock).
# The fixed path is mounted into workspace containers as a DIRECTORY mount, so when
# socat recreates the socket after SSH reconnect, containers see the new socket.
# Must be BEFORE the non-interactive guard in .bashrc so it runs for all sessions.
log "Setting up SSH agent forwarding for tmux + containers..."

AGENT_BLOCK='# --- SSH agent forwarding through tmux + containers ---
# Proxy SSH agent socket to a fixed path via socat. The ~/.ssh-agent/ directory
# is mounted into workspace containers, so they always have access to the agent.
if [ -n "$SSH_AUTH_SOCK" ] && [ "$SSH_AUTH_SOCK" != "$HOME/.ssh-agent/agent.sock" ]; then
    pkill -f "socat.*\.ssh-agent/agent\.sock" 2>/dev/null || true
    rm -f "$HOME/.ssh-agent/agent.sock"
    nohup socat UNIX-LISTEN:"$HOME/.ssh-agent/agent.sock",fork UNIX-CONNECT:"$SSH_AUTH_SOCK" </dev/null >/dev/null 2>&1 &
    export SSH_AUTH_SOCK="$HOME/.ssh-agent/agent.sock"
fi
'

# Remove any existing agent block from .bashrc (handles upgrades from symlink to socat)
sed -i '/# --- SSH agent forwarding through tmux/,/^fi$/d' "$AGENTBOX_HOME/.bashrc" 2>/dev/null || true
# Prepend new block (before the non-interactive guard)
printf '%s\n' "$AGENT_BLOCK" | cat - "$AGENTBOX_HOME/.bashrc" > /tmp/.bashrc.tmp
mv /tmp/.bashrc.tmp "$AGENTBOX_HOME/.bashrc"

chown agentbox:agentbox "$AGENTBOX_HOME/.bashrc"

# --- Done ---
log ""
log "=== Setup complete ==="
log "  User: agentbox"
log "  Node: $NODE_VERSION"
log "  Claude Code: $CLAUDE_VERSION"
log "  VS Code CLI: $(code version 2>/dev/null | head -1 || echo 'n/a')"
log "  GitHub CLI: $(gh --version 2>/dev/null | head -1 || echo 'n/a')"
log "  Python: $(python3 --version 2>/dev/null || echo 'n/a')"
log "  Docker: $(docker --version 2>/dev/null || echo 'n/a')"
log "  Compose: $(docker compose version 2>/dev/null || echo 'n/a')"
log "  tmux: $(tmux -V)"
log ""

#!/usr/bin/env bash
#
# setup-vm.sh — Runs on the Hetzner VM as root.
# Installs Node.js LTS, tmux, Claude Code, dev tools. Hardens SSH. Creates agentbox user.
#
set -euo pipefail

LOG_PREFIX="[setup-vm]"
log()  { echo "$LOG_PREFIX $1"; }
err()  { echo "$LOG_PREFIX ERROR: $1" >&2; }

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
  htop

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

# --- Create agentbox user ---
log "Creating agentbox user..."
if ! id -u agentbox &>/dev/null; then
  useradd -m -s /bin/bash -G sudo agentbox
  # Allow sudo without password for agentbox
  echo "agentbox ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agentbox
fi

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
set -g status-left '[agentbox] '
set -g status-right '%H:%M '

# Don't auto-rename windows
set -g allow-rename off
TMUX

chown agentbox:agentbox "$AGENTBOX_HOME/.tmux.conf"

# --- Done ---
log ""
log "=== Setup complete ==="
log "  User: agentbox"
log "  Node: $NODE_VERSION"
log "  Claude Code: $CLAUDE_VERSION"
log "  tmux: $(tmux -V)"
log ""

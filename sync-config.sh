#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/.agentbox-state"
KNOWN_HOSTS_FILE="$SCRIPT_DIR/.agentbox-known-hosts"

VM_USER="agentbox"
VM_HOME="/home/$VM_USER"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[sync]${NC} $1"; }
warn() { echo -e "${YELLOW}[sync]${NC} $1"; }
err()  { echo -e "${RED}[sync]${NC} $1" >&2; }

# --- SSH helpers (same pattern as provision.sh) ---
SSH_OPTS=(-o "UserKnownHostsFile=$KNOWN_HOSTS_FILE" -o "StrictHostKeyChecking=no")

vm_ssh() {
  ssh "${SSH_OPTS[@]}" "$@"
}

vm_rsync() {
  rsync -az -e "ssh ${SSH_OPTS[*]}" "$@"
}

vm_scp() {
  scp "${SSH_OPTS[@]}" "$@"
}

# --- Resolve VM IP ---
resolve_ip() {
  if [[ -n "${1:-}" ]]; then
    SERVER_IP="$1"
  elif [[ -f "$STATE_FILE" ]]; then
    SERVER_IP="$(grep '^SERVER_IP=' "$STATE_FILE" | cut -d= -f2-)"
  fi

  if [[ -z "${SERVER_IP:-}" ]]; then
    err "No VM IP provided."
    err "Usage: $0 [ip]"
    err "Or ensure .agentbox-state exists (run provision.sh first)."
    exit 1
  fi
}

# --- Test SSH connectivity ---
test_ssh() {
  log "Testing SSH connection to $SERVER_IP..."
  if ! vm_ssh -o ConnectTimeout=5 -o BatchMode=yes "$VM_USER@$SERVER_IP" "echo ok" &>/dev/null; then
    err "Cannot connect to $VM_USER@$SERVER_IP"
    exit 1
  fi
}

# --- Sync helpers ---
SYNCED=()

sync_gitconfig() {
  local src="$HOME/.gitconfig"
  if [[ ! -f "$src" ]]; then
    warn "~/.gitconfig not found, skipping"
    return
  fi

  log "Syncing .gitconfig..."
  # Dereference symlinks (-L) so we copy the actual file
  if [[ -L "$src" ]]; then
    vm_scp -q "$(readlink -f "$src")" "$VM_USER@$SERVER_IP:$VM_HOME/.gitconfig"
  else
    vm_scp -q "$src" "$VM_USER@$SERVER_IP:$VM_HOME/.gitconfig"
  fi
  SYNCED+=(".gitconfig")
}

sync_ssh() {
  local src="$HOME/.ssh"
  if [[ ! -d "$src" ]]; then
    warn "~/.ssh/ not found, skipping"
    return
  fi

  log "Syncing .ssh/ (preserving authorized_keys)..."

  # Backup existing authorized_keys on VM
  vm_ssh "$VM_USER@$SERVER_IP" \
    "cp $VM_HOME/.ssh/authorized_keys /tmp/.ads_authorized_keys_backup 2>/dev/null || true"

  # Sync SSH dir — keys, config, known_hosts
  # Exclude authorized_keys to avoid overwriting VM's provisioned keys
  if command -v rsync &>/dev/null; then
    vm_rsync \
      --copy-links \
      --exclude='authorized_keys' \
      --exclude='*.sock' \
      "$src/" "$VM_USER@$SERVER_IP:$VM_HOME/.ssh/"
  else
    # Fallback: copy individual files
    for f in "$src"/id_* "$src"/config "$src"/known_hosts; do
      [[ -f "$f" ]] && vm_scp -q "$f" "$VM_USER@$SERVER_IP:$VM_HOME/.ssh/"
    done
  fi

  # Restore authorized_keys from backup
  vm_ssh "$VM_USER@$SERVER_IP" \
    "cp /tmp/.ads_authorized_keys_backup $VM_HOME/.ssh/authorized_keys 2>/dev/null || true; \
     rm -f /tmp/.ads_authorized_keys_backup"

  # Fix permissions
  vm_ssh "$VM_USER@$SERVER_IP" \
    "chmod 700 $VM_HOME/.ssh && chmod 600 $VM_HOME/.ssh/* 2>/dev/null; \
     chmod 644 $VM_HOME/.ssh/*.pub 2>/dev/null; \
     chmod 644 $VM_HOME/.ssh/authorized_keys 2>/dev/null; \
     chmod 644 $VM_HOME/.ssh/known_hosts 2>/dev/null; \
     true"

  SYNCED+=(".ssh/")
}

sync_claude() {
  local src="$HOME/.claude"
  if [[ ! -d "$src" ]]; then
    warn "~/.claude/ not found, skipping"
    return
  fi

  log "Syncing .claude/ (excluding transient data)..."

  # Ensure target dir exists
  vm_ssh "$VM_USER@$SERVER_IP" "mkdir -p $VM_HOME/.claude"

  if command -v rsync &>/dev/null; then
    vm_rsync \
      --copy-links \
      --exclude='statsig/' \
      --exclude='todos/' \
      --exclude='.credentials' \
      --exclude='*.log' \
      "$src/" "$VM_USER@$SERVER_IP:$VM_HOME/.claude/"
  else
    # Fallback: copy key files individually
    for f in "$src"/CLAUDE.md "$src"/settings.json "$src"/settings.local.json; do
      [[ -f "$f" ]] && vm_scp -q "$f" "$VM_USER@$SERVER_IP:$VM_HOME/.claude/"
    done
    # Copy projects dir if it exists
    if [[ -d "$src/projects" ]]; then
      vm_scp -q -r "$src/projects" "$VM_USER@$SERVER_IP:$VM_HOME/.claude/"
    fi
  fi

  SYNCED+=(".claude/")
}

# --- Main ---
main() {
  echo ""
  echo -e "${CYAN}=== Agent Dev Space — Config Sync ===${NC}"
  echo ""

  resolve_ip "${1:-}"
  test_ssh

  sync_gitconfig
  sync_ssh
  sync_claude

  # Fix ownership for everything we touched
  vm_ssh "$VM_USER@$SERVER_IP" \
    "chown -R $VM_USER:$VM_USER $VM_HOME/.gitconfig $VM_HOME/.ssh $VM_HOME/.claude 2>/dev/null || true"

  echo ""
  if [[ ${#SYNCED[@]} -eq 0 ]]; then
    warn "Nothing to sync — no local configs found."
  else
    log "Synced to $VM_USER@$SERVER_IP: ${SYNCED[*]}"
  fi
  echo ""
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
SETUP_SCRIPT="$SCRIPT_DIR/scripts/setup-vm.sh"
STATE_FILE="$SCRIPT_DIR/.agentbox-state"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[agentbox]${NC} $1"; }
warn() { echo -e "${YELLOW}[agentbox]${NC} $1"; }
err()  { echo -e "${RED}[agentbox]${NC} $1" >&2; }

# --- Load .env ---
if [[ ! -f "$ENV_FILE" ]]; then
  err ".env file not found. Copy .env.example to .env and fill in required values."
  err "  cp .env.example .env"
  exit 1
fi

# Parse .env explicitly (don't source arbitrary files)
parse_env() {
  local key="$1"
  local default="${2:-}"
  local value
  value="$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)"
  # Trim surrounding quotes if present
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  echo "${value:-$default}"
}

HETZNER_API_TOKEN="$(parse_env HETZNER_API_TOKEN)"
ANTHROPIC_API_KEY="$(parse_env ANTHROPIC_API_KEY)"
SSH_PUBLIC_KEY_PATH="$(parse_env SSH_PUBLIC_KEY_PATH "$HOME/.ssh/id_ed25519.pub")"
HETZNER_REGION="$(parse_env HETZNER_REGION "nbg1")"
HETZNER_SERVER_TYPE="$(parse_env HETZNER_SERVER_TYPE "")"

# --- Validate required values ---
if [[ -z "$HETZNER_API_TOKEN" ]]; then
  err "HETZNER_API_TOKEN is required in .env"
  exit 1
fi

if [[ -z "$ANTHROPIC_API_KEY" ]]; then
  err "ANTHROPIC_API_KEY is required in .env"
  exit 1
fi

# --- Defaults ---
SERVER_NAME="agentbox-$(date +%s)"

HETZNER_API="https://api.hetzner.cloud/v1"

# --- Validate SSH key exists ---
if [[ ! -f "$SSH_PUBLIC_KEY_PATH" ]]; then
  err "SSH public key not found at: $SSH_PUBLIC_KEY_PATH"
  err "Set SSH_PUBLIC_KEY_PATH in .env or generate a key with: ssh-keygen -t ed25519"
  exit 1
fi

SSH_PUBLIC_KEY="$(cat "$SSH_PUBLIC_KEY_PATH")"

# --- Validate setup script exists ---
if [[ ! -f "$SETUP_SCRIPT" ]]; then
  err "Setup script not found at: $SETUP_SCRIPT"
  exit 1
fi

# --- Hetzner API helper ---
hetzner_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  local args=(
    -s
    -X "$method"
    -H "Authorization: Bearer $HETZNER_API_TOKEN"
    -H "Content-Type: application/json"
    -w '\n%{http_code}'
  )

  if [[ -n "$data" ]]; then
    args+=(-d "$data")
  fi

  local raw
  raw="$(curl "${args[@]}" "${HETZNER_API}${endpoint}")"

  local http_code
  http_code="$(echo "$raw" | tail -1)"
  local body
  body="$(echo "$raw" | sed '$d')"

  if [[ "$http_code" -ge 400 ]]; then
    local api_error
    api_error="$(echo "$body" | jq -r '.error.message // empty' 2>/dev/null)"
    err "Hetzner API ${method} ${endpoint} failed (HTTP ${http_code})"
    if [[ -n "$api_error" ]]; then
      err "  $api_error"
    else
      err "  $body"
    fi
    exit 1
  fi

  echo "$body"
}

# --- Server type selection ---
select_server_type() {
  if [[ -n "$HETZNER_SERVER_TYPE" ]]; then
    log "Server type from .env: $HETZNER_SERVER_TYPE"
    return
  fi

  echo ""
  echo -e "${CYAN}Select server type:${NC}"
  echo "  1) cx22  — 2 vCPU,   4GB RAM,   40GB SSD — ~€4/mo"
  echo "  2) cx32  — 4 vCPU,   8GB RAM,   80GB SSD — ~€8/mo"
  echo "  3) cx42  — 8 vCPU,  16GB RAM,  160GB SSD — ~€16/mo"
  echo "  4) cx52  — 16 vCPU, 32GB RAM,  320GB SSD — ~€31/mo"
  echo ""

  local choice
  read -rp "Choice [1]: " choice
  choice="${choice:-1}"

  case "$choice" in
    1) HETZNER_SERVER_TYPE="cx22" ;;
    2) HETZNER_SERVER_TYPE="cx32" ;;
    3) HETZNER_SERVER_TYPE="cx42" ;;
    4) HETZNER_SERVER_TYPE="cx52" ;;
    *)
      err "Invalid choice: $choice"
      exit 1
      ;;
  esac

  log "Selected: $HETZNER_SERVER_TYPE"
}

# --- Upload SSH key to Hetzner ---
upload_ssh_key() {
  local key_name="agentbox-$(echo "$SSH_PUBLIC_KEY" | md5sum | cut -c1-8 2>/dev/null || echo "$SSH_PUBLIC_KEY" | md5 -q | cut -c1-8)"

  log "Checking for existing SSH key on Hetzner..."

  local existing_keys
  existing_keys="$(hetzner_api GET /ssh_keys)"

  local existing_id
  existing_id="$(echo "$existing_keys" | jq -r --arg fp "$SSH_PUBLIC_KEY" \
    '.ssh_keys[] | select(.public_key == $fp) | .id' | head -1)"

  if [[ -n "$existing_id" ]]; then
    log "SSH key already exists on Hetzner (id: $existing_id)"
    SSH_KEY_ID="$existing_id"
    return
  fi

  log "Uploading SSH key to Hetzner..."
  local response
  response="$(hetzner_api POST /ssh_keys "$(jq -n \
    --arg name "$key_name" \
    --arg key "$SSH_PUBLIC_KEY" \
    '{name: $name, public_key: $key}')")"

  SSH_KEY_ID="$(echo "$response" | jq -r '.ssh_key.id')"

  if [[ -z "$SSH_KEY_ID" || "$SSH_KEY_ID" == "null" ]]; then
    err "Failed to upload SSH key"
    err "$response"
    exit 1
  fi

  log "SSH key uploaded (id: $SSH_KEY_ID)"
}

# --- Create server ---
create_server() {
  log "Creating Hetzner server: $SERVER_NAME ($HETZNER_SERVER_TYPE in $HETZNER_REGION)..."

  local response
  response="$(hetzner_api POST /servers "$(jq -n \
    --arg name "$SERVER_NAME" \
    --arg type "$HETZNER_SERVER_TYPE" \
    --arg image "ubuntu-24.04" \
    --arg location "$HETZNER_REGION" \
    --argjson ssh_keys "[$SSH_KEY_ID]" \
    '{
      name: $name,
      server_type: $type,
      image: $image,
      location: $location,
      ssh_keys: $ssh_keys,
      start_after_create: true
    }')")"

  SERVER_ID="$(echo "$response" | jq -r '.server.id')"
  SERVER_IP="$(echo "$response" | jq -r '.server.public_net.ipv4.ip')"

  if [[ -z "$SERVER_ID" || "$SERVER_ID" == "null" ]]; then
    err "Failed to create server"
    err "$response"
    exit 1
  fi

  log "Server created (id: $SERVER_ID)"
}

# --- Wait for server to be ready ---
wait_for_server() {
  log "Waiting for server to be running..."

  local status=""
  local attempts=0
  local max_attempts=60

  while [[ "$status" != "running" ]]; do
    if (( attempts >= max_attempts )); then
      err "Server did not start within ${max_attempts} attempts"
      exit 1
    fi

    sleep 5
    local response
    response="$(hetzner_api GET "/servers/$SERVER_ID")"
    status="$(echo "$response" | jq -r '.server.status')"
    SERVER_IP="$(echo "$response" | jq -r '.server.public_net.ipv4.ip')"
    attempts=$((attempts + 1))
    echo -n "."
  done

  echo ""
  log "Server is running at $SERVER_IP"
}

# --- Wait for SSH to be available ---
wait_for_ssh() {
  log "Waiting for SSH to become available..."

  local attempts=0
  local max_attempts=30

  while ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
    "root@$SERVER_IP" "echo ok" &>/dev/null; do
    if (( attempts >= max_attempts )); then
      err "SSH did not become available within ${max_attempts} attempts"
      exit 1
    fi
    sleep 5
    attempts=$((attempts + 1))
    echo -n "."
  done

  echo ""
  log "SSH is ready"
}

# --- Pin SSH host key ---
pin_host_key() {
  log "Pinning SSH host key..."
  local known_hosts_file="$SCRIPT_DIR/.agentbox-known-hosts"

  # Remove stale entry if re-provisioning
  ssh-keygen -R "$SERVER_IP" -f "$known_hosts_file" &>/dev/null || true

  local attempts=0
  local max_attempts=10
  while ! ssh-keyscan -t ed25519 "$SERVER_IP" >> "$known_hosts_file" 2>/dev/null; do
    if (( attempts >= max_attempts )); then
      err "Could not obtain host key"
      exit 1
    fi
    sleep 3
    attempts=$((attempts + 1))
  done

  SSH_OPTS=(-o "UserKnownHostsFile=$known_hosts_file" -o "StrictHostKeyChecking=yes")
  log "Host key pinned"
}

# --- Run setup script on VM ---
run_setup() {
  log "Copying setup script to VM..."
  scp "${SSH_OPTS[@]}" "$SETUP_SCRIPT" "root@$SERVER_IP:/tmp/setup-vm.sh"

  log "Deploying API key to VM..."
  ssh "${SSH_OPTS[@]}" "root@$SERVER_IP" \
    "cat > /tmp/agentbox-env && chmod 600 /tmp/agentbox-env" \
    <<< "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"

  log "Running setup script on VM (this may take a few minutes)..."
  ssh "${SSH_OPTS[@]}" "root@$SERVER_IP" \
    "bash /tmp/setup-vm.sh && rm -f /tmp/setup-vm.sh /tmp/agentbox-env"
}

# --- Save state ---
save_state() {
  cat > "$STATE_FILE" <<EOF
SERVER_ID=$SERVER_ID
SERVER_IP=$SERVER_IP
SERVER_NAME=$SERVER_NAME
SERVER_TYPE=$HETZNER_SERVER_TYPE
REGION=$HETZNER_REGION
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  log "State saved to $STATE_FILE"
}

# --- Main ---
main() {
  echo ""
  echo -e "${CYAN}=== AgentBox Provisioner ===${NC}"
  echo ""

  select_server_type
  upload_ssh_key
  create_server
  wait_for_server
  wait_for_ssh
  pin_host_key
  run_setup
  save_state

  echo ""
  echo -e "${GREEN}=== Provisioning complete ===${NC}"
  echo ""
  echo -e "  ${CYAN}SSH:${NC}     ssh agentbox@$SERVER_IP"
  echo -e "  ${CYAN}Server:${NC}  $SERVER_NAME ($HETZNER_SERVER_TYPE)"
  echo -e "  ${CYAN}Region:${NC}  $HETZNER_REGION"
  echo -e "  ${CYAN}ID:${NC}      $SERVER_ID"
  echo ""
  echo -e "  ${YELLOW}To start coding:${NC}"
  echo "    ssh agentbox@$SERVER_IP"
  echo "    tmux new-session -s claude"
  echo "    claude"
  echo ""
  echo -e "  ${YELLOW}To reconnect later:${NC}"
  echo "    ssh agentbox@$SERVER_IP"
  echo "    tmux attach -t claude"
  echo ""
}

main "$@"

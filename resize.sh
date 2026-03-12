#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
STATE_FILE="$SCRIPT_DIR/.agentbox-state"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[ads]${NC} $1"; }
warn() { echo -e "${YELLOW}[ads]${NC} $1"; }
err()  { echo -e "${RED}[ads]${NC} $1" >&2; }

# --- Load .env ---
if [[ ! -f "$ENV_FILE" ]]; then
  err ".env file not found."
  exit 1
fi

if [[ ! -f "$STATE_FILE" ]]; then
  err "No state file found. Nothing to resize."
  exit 1
fi

# Parse .env
parse_env() {
  local key="$1"
  local default="${2:-}"
  local value
  value="$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  echo "${value:-$default}"
}

HETZNER_API_TOKEN="$(parse_env HETZNER_API_TOKEN)"
HETZNER_API="https://api.hetzner.cloud/v1"

# Parse state
SERVER_ID="$(grep '^SERVER_ID=' "$STATE_FILE" | cut -d= -f2-)"
SERVER_IP="$(grep '^SERVER_IP=' "$STATE_FILE" | cut -d= -f2-)"
SERVER_NAME="$(grep '^SERVER_NAME=' "$STATE_FILE" | cut -d= -f2-)"
CURRENT_TYPE="$(grep '^SERVER_TYPE=' "$STATE_FILE" | cut -d= -f2-)"
REGION="$(grep '^REGION=' "$STATE_FILE" | cut -d= -f2-)"

if [[ -z "$HETZNER_API_TOKEN" ]]; then
  err "HETZNER_API_TOKEN not found in .env"
  exit 1
fi

if [[ -z "$SERVER_ID" ]]; then
  err "No SERVER_ID in state file"
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

# --- Wait for action to complete ---
wait_for_action() {
  local action_id="$1"
  local label="$2"
  local status=""
  local attempts=0
  local max_attempts=60

  while [[ "$status" != "success" ]]; do
    if [[ "$status" == "error" ]]; then
      err "$label failed"
      exit 1
    fi
    if (( attempts >= max_attempts )); then
      err "$label did not complete within ${max_attempts} attempts"
      exit 1
    fi
    sleep 3
    local response
    response="$(hetzner_api GET "/actions/$action_id")"
    status="$(echo "$response" | jq -r '.action.status')"
    attempts=$((attempts + 1))
    echo -n "."
  done
  echo ""
}

# --- Server type selection ---
echo ""
echo -e "${CYAN}=== Resize Server ===${NC}"
echo ""
log "Current server: $SERVER_NAME (id: $SERVER_ID)"
log "Current type:   $CURRENT_TYPE"
echo ""
echo -e "${CYAN}Select new server type:${NC}"
echo "  1) cx22  — 2 vCPU,   4GB RAM,   40GB SSD — ~€4/mo"
echo "  2) cx32  — 4 vCPU,   8GB RAM,   80GB SSD — ~€7/mo"
echo "  3) cx42  — 8 vCPU,  16GB RAM,  160GB SSD — ~€14/mo"
echo "  4) cx52  — 16 vCPU, 32GB RAM,  320GB SSD — ~€29/mo"
echo ""

read -rp "Choice: " choice

case "$choice" in
  1) NEW_TYPE="cx22" ;;
  2) NEW_TYPE="cx32" ;;
  3) NEW_TYPE="cx42" ;;
  4) NEW_TYPE="cx52" ;;
  *)
    err "Invalid choice: $choice"
    exit 1
    ;;
esac

if [[ "$NEW_TYPE" == "$CURRENT_TYPE" ]]; then
  warn "Server is already $CURRENT_TYPE. Nothing to do."
  exit 0
fi

# Determine if this is an upgrade or downgrade for disk handling
# Disk upgrade is irreversible — only enable if going to a larger type
UPGRADE_DISK=true

echo ""
warn "This will resize $SERVER_NAME from $CURRENT_TYPE → $NEW_TYPE"
warn "The server will be powered off during the resize."
warn "Disk upgrade: $UPGRADE_DISK (disk will grow to match new type)"
echo ""
read -rp "Type 'yes' to confirm: " confirm

if [[ "$confirm" != "yes" ]]; then
  log "Aborted."
  exit 0
fi

# --- Step 1: Power off ---
log "Powering off server..."
response="$(hetzner_api POST "/servers/$SERVER_ID/actions/poweroff")"
action_id="$(echo "$response" | jq -r '.action.id')"
wait_for_action "$action_id" "Power off"
log "Server powered off."

# --- Step 2: Change type ---
log "Changing server type to $NEW_TYPE..."
response="$(hetzner_api POST "/servers/$SERVER_ID/actions/change_type" "$(jq -n \
  --arg type "$NEW_TYPE" \
  --argjson upgrade_disk "$UPGRADE_DISK" \
  '{server_type: $type, upgrade_disk: $upgrade_disk}')")"
action_id="$(echo "$response" | jq -r '.action.id')"
wait_for_action "$action_id" "Change type"
log "Server type changed to $NEW_TYPE."

# --- Step 3: Power on ---
log "Powering on server..."
response="$(hetzner_api POST "/servers/$SERVER_ID/actions/poweron")"
action_id="$(echo "$response" | jq -r '.action.id')"
wait_for_action "$action_id" "Power on"
log "Server powered on."

# --- Step 4: Update state file ---
cat > "$STATE_FILE" <<EOF
SERVER_ID=$SERVER_ID
SERVER_IP=$SERVER_IP
SERVER_NAME=$SERVER_NAME
SERVER_TYPE=$NEW_TYPE
REGION=$REGION
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

echo ""
echo -e "${GREEN}=== Resize complete ===${NC}"
echo ""
echo -e "  ${CYAN}Server:${NC}  $SERVER_NAME"
echo -e "  ${CYAN}Type:${NC}    $CURRENT_TYPE → $NEW_TYPE"
echo -e "  ${CYAN}IP:${NC}      $SERVER_IP"
echo ""

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
echo -e "${CYAN}Shared vCPU — Intel/AMD (CX):${NC}"
echo "   1) cx23   —  2 vCPU,   4GB RAM,   40GB SSD"
echo "   2) cx33   —  4 vCPU,   8GB RAM,   80GB SSD"
echo "   3) cx43   —  8 vCPU,  16GB RAM,  160GB SSD"
echo "   4) cx53   — 16 vCPU,  32GB RAM,  320GB SSD"
echo ""
echo -e "${CYAN}Shared vCPU — ARM64 (CAX):${NC}"
echo "   5) cax11  —  2 vCPU,   4GB RAM,   40GB SSD"
echo "   6) cax21  —  4 vCPU,   8GB RAM,   80GB SSD"
echo "   7) cax31  —  8 vCPU,  16GB RAM,  160GB SSD"
echo "   8) cax41  — 16 vCPU,  32GB RAM,  320GB SSD"
echo ""
echo -e "${CYAN}Dedicated vCPU — AMD (CPX):${NC}"
echo "   9) cpx12  —  1 vCPU,   2GB RAM,   40GB SSD"
echo "  10) cpx22  —  2 vCPU,   4GB RAM,   80GB SSD"
echo "  11) cpx32  —  4 vCPU,   8GB RAM,  160GB SSD"
echo "  12) cpx42  —  8 vCPU,  16GB RAM,  320GB SSD"
echo "  13) cpx52  — 12 vCPU,  24GB RAM,  480GB SSD"
echo "  14) cpx62  — 16 vCPU,  32GB RAM,  640GB SSD"
echo ""
echo -e "${CYAN}Dedicated vCPU — AMD High-Memory (CCX):${NC}"
echo "  15) ccx13  —  2 vCPU,   8GB RAM,   80GB SSD"
echo "  16) ccx23  —  4 vCPU,  16GB RAM,  160GB SSD"
echo "  17) ccx33  —  8 vCPU,  32GB RAM,  240GB SSD"
echo "  18) ccx43  — 16 vCPU,  64GB RAM,  360GB SSD"
echo "  19) ccx53  — 32 vCPU, 128GB RAM,  600GB SSD"
echo "  20) ccx63  — 48 vCPU, 192GB RAM,  960GB SSD"
echo ""
echo -e "${CYAN}Custom:${NC}"
echo "   c) Enter a custom server type name"
echo ""

read -rp "Choice [1-20 or c]: " choice

case "$choice" in
   1) NEW_TYPE="cx23"  ;;
   2) NEW_TYPE="cx33"  ;;
   3) NEW_TYPE="cx43"  ;;
   4) NEW_TYPE="cx53"  ;;
   5) NEW_TYPE="cax11" ;;
   6) NEW_TYPE="cax21" ;;
   7) NEW_TYPE="cax31" ;;
   8) NEW_TYPE="cax41" ;;
   9) NEW_TYPE="cpx12" ;;
  10) NEW_TYPE="cpx22" ;;
  11) NEW_TYPE="cpx32" ;;
  12) NEW_TYPE="cpx42" ;;
  13) NEW_TYPE="cpx52" ;;
  14) NEW_TYPE="cpx62" ;;
  15) NEW_TYPE="ccx13" ;;
  16) NEW_TYPE="ccx23" ;;
  17) NEW_TYPE="ccx33" ;;
  18) NEW_TYPE="ccx43" ;;
  19) NEW_TYPE="ccx53" ;;
  20) NEW_TYPE="ccx63" ;;
  c|C)
    read -rp "Enter server type name (e.g. cx23, cax31): " NEW_TYPE
    if [[ -z "$NEW_TYPE" ]]; then
      err "No server type provided."
      exit 1
    fi
    ;;
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

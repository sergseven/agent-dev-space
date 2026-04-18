#!/usr/bin/env bash
# init-state.sh — Populate .agentbox-state from an existing Hetzner VM.
# Use this on a new machine when the VM is already running.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
STATE_FILE="$PROJECT_DIR/.agentbox-state"

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
  err ".env file not found. Copy .env.example to .env and set HETZNER_API_TOKEN."
  exit 1
fi

parse_env() {
  local key="$1" default="${2:-}" value
  value="$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)"
  value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"
  echo "${value:-$default}"
}

HETZNER_API_TOKEN="$(parse_env HETZNER_API_TOKEN)"
if [[ -z "$HETZNER_API_TOKEN" ]]; then
  err "HETZNER_API_TOKEN is required in .env"
  exit 1
fi

HETZNER_API="https://api.hetzner.cloud/v1"

hetzner_api() {
  local method="$1" endpoint="$2"
  local raw http_code body
  raw="$(curl -s -X "$method" \
    -H "Authorization: Bearer $HETZNER_API_TOKEN" \
    -H "Content-Type: application/json" \
    -w '\n%{http_code}' \
    "${HETZNER_API}${endpoint}")"
  http_code="$(echo "$raw" | tail -1)"
  body="$(echo "$raw" | sed '$d')"
  if [[ "$http_code" -ge 400 ]]; then
    err "Hetzner API $method $endpoint failed (HTTP $http_code)"
    err "  $(echo "$body" | jq -r '.error.message // empty' 2>/dev/null || echo "$body")"
    exit 1
  fi
  echo "$body"
}

# --- Fetch servers ---
echo ""
echo -e "${CYAN}=== Agent Dev Space — Init ===${NC}"
echo ""
log "Fetching servers from Hetzner..."

response="$(hetzner_api GET /servers)"
server_count="$(echo "$response" | jq '.servers | length')"

if [[ "$server_count" -eq 0 ]]; then
  err "No servers found on this Hetzner account."
  err "Run 'task provision' to create one."
  exit 1
fi

# Build parallel arrays (mapfile-free, works on bash 3 / macOS)
IDS=()    NAMES=()  IPS=()    TYPES=()  REGIONS=() DATES=()
while IFS=$'\t' read -r id name ip type region created; do
  IDS+=("$id") NAMES+=("$name") IPS+=("$ip")
  TYPES+=("$type") REGIONS+=("$region") DATES+=("$created")
done < <(echo "$response" | jq -r \
  '.servers[] | [.id, .name, .public_net.ipv4.ip, .server_type.name, .datacenter.location.name, .created] | @tsv')

if [[ "$server_count" -eq 1 ]]; then
  idx=0
  log "Found 1 server: ${NAMES[0]} (${IPS[0]})"
else
  echo -e "  ${CYAN}Select a server:${NC}"
  echo ""
  for (( i=0; i<server_count; i++ )); do
    printf "  %d) %-30s  %-15s  %s  %s\n" \
      "$((i+1))" "${NAMES[$i]}" "${IPS[$i]}" "${TYPES[$i]}" "${REGIONS[$i]}"
  done
  echo ""
  read -rp "Choice [1]: " choice
  choice="${choice:-1}"
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > server_count )); then
    err "Invalid choice: $choice"
    exit 1
  fi
  idx=$((choice - 1))
fi

SERVER_ID="${IDS[$idx]}"
SERVER_IP="${IPS[$idx]}"
SERVER_NAME="${NAMES[$idx]}"
SERVER_TYPE="${TYPES[$idx]}"
REGION="${REGIONS[$idx]}"
CREATED_AT="${DATES[$idx]}"

cat > "$STATE_FILE" <<EOF
SERVER_ID=$SERVER_ID
SERVER_IP=$SERVER_IP
SERVER_NAME=$SERVER_NAME
SERVER_TYPE=$SERVER_TYPE
REGION=$REGION
CREATED_AT=$CREATED_AT
EOF

log "State written to .agentbox-state"
echo ""
echo -e "  Server:  ${SERVER_NAME} (${SERVER_TYPE}, ${REGION})"
echo -e "  IP:      ${SERVER_IP}"
echo -e "  ID:      ${SERVER_ID}"
echo ""
echo -e "  ${GREEN}Run 'task connect' to connect.${NC}"
echo ""

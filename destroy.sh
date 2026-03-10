#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
STATE_FILE="$SCRIPT_DIR/.agentbox-state"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[ads]${NC} $1"; }
warn() { echo -e "${YELLOW}[ads]${NC} $1"; }
err()  { echo -e "${RED}[ads]${NC} $1" >&2; }

if [[ ! -f "$ENV_FILE" ]]; then
  err ".env file not found"
  exit 1
fi

if [[ ! -f "$STATE_FILE" ]]; then
  err "No state file found. Nothing to destroy."
  exit 1
fi

# Parse .env for API token only (don't source untrusted files)
HETZNER_API_TOKEN="$(grep '^HETZNER_API_TOKEN=' "$ENV_FILE" | cut -d= -f2-)"

# Parse state file explicitly
SERVER_ID="$(grep '^SERVER_ID=' "$STATE_FILE" | cut -d= -f2-)"
SERVER_IP="$(grep '^SERVER_IP=' "$STATE_FILE" | cut -d= -f2-)"
SERVER_NAME="$(grep '^SERVER_NAME=' "$STATE_FILE" | cut -d= -f2-)"

if [[ -z "${HETZNER_API_TOKEN:-}" ]]; then
  err "HETZNER_API_TOKEN not found in .env"
  exit 1
fi

if [[ -z "${SERVER_ID:-}" ]]; then
  err "No SERVER_ID in state file"
  exit 1
fi

warn "This will permanently delete server: $SERVER_NAME ($SERVER_IP)"
warn "Server ID: $SERVER_ID"
echo ""
read -rp "Type 'yes' to confirm: " confirm

if [[ "$confirm" != "yes" ]]; then
  log "Aborted."
  exit 0
fi

log "Deleting server $SERVER_ID..."

response="$(curl -s -w '\n%{http_code}' \
  -X DELETE \
  -H "Authorization: Bearer $HETZNER_API_TOKEN" \
  "https://api.hetzner.cloud/v1/servers/$SERVER_ID")"

http_code="$(echo "$response" | tail -1)"

if [[ "$http_code" != "200" && "$http_code" != "204" ]]; then
  err "DELETE failed with HTTP $http_code. State file NOT removed."
  err "$(echo "$response" | sed '$d')"
  exit 1
fi

rm -f "$STATE_FILE"

log "Server destroyed. State file removed."

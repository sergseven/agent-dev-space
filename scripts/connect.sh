#!/usr/bin/env bash
#
# connect.sh — Interactive tmux session selector with TUI.
# Lists existing sessions, lets you pick one or create a new one.
# Runs locally, SSHes into the VM to manage tmux.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATE_FILE="$PROJECT_DIR/.agentbox-state"
KNOWN_HOSTS="$PROJECT_DIR/.agentbox-known-hosts"
SSH_OPTS=(-A -o "UserKnownHostsFile=$KNOWN_HOSTS" -o "StrictHostKeyChecking=no")

# --- Colors & drawing ---
BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
WHITE='\033[1;37m'
BG_CYAN='\033[46m'
BG_DARK='\033[48;5;236m'
NC='\033[0m'

# --- Helpers ---
err() { echo -e "${RED}[ads]${NC} $1" >&2; }

get_server_ip() {
  if [[ ! -f "$STATE_FILE" ]]; then
    err "No state file found. Run 'task provision' first."
    exit 1
  fi
  grep '^SERVER_IP=' "$STATE_FILE" | cut -d= -f2-
}

vm_ssh() {
  ssh "${SSH_OPTS[@]}" "$@"
}

# --- Fetch tmux sessions from VM ---
fetch_sessions() {
  local ip="$1"
  # Returns: session_name:windows:created_timestamp:attached_or_not
  vm_ssh "agentbox@$ip" \
    "tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_created}|#{?session_attached,attached,detached}' 2>/dev/null" \
    || true
}

# --- Format timestamp to human-readable ---
format_time() {
  local ts="$1"
  if date --version &>/dev/null 2>&1; then
    # GNU date
    date -d "@$ts" "+%b %d %H:%M" 2>/dev/null || echo "unknown"
  else
    # BSD date (macOS)
    date -r "$ts" "+%b %d %H:%M" 2>/dev/null || echo "unknown"
  fi
}

# --- TUI session selector ---
run_selector() {
  local ip="$1"
  local raw_sessions
  raw_sessions="$(fetch_sessions "$ip")"

  # Parse sessions into arrays
  local -a names=()
  local -a details=()
  local -a statuses=()

  while IFS='|' read -r name windows created status; do
    [[ -z "$name" ]] && continue
    names+=("$name")
    local time_str
    time_str="$(format_time "$created")"
    details+=("${windows} window(s) · created $time_str")
    statuses+=("$status")
  done <<< "$raw_sessions"

  local session_count=${#names[@]}
  local total_items=$((session_count + 1))  # +1 for "New session"
  local selected=0

  # Hide cursor, enable alternate screen
  tput civis 2>/dev/null || true
  # Save terminal state for cleanup
  trap 'tput cnorm 2>/dev/null; tput sgr0 2>/dev/null' EXIT INT TERM

  while true; do
    # Clear screen and draw
    printf '\033[2J\033[H'

    # Header
    echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}  ║       Agent Dev Space · Connect         ║${NC}"
    echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${DIM}Server: ${NC}${WHITE}$ip${NC}"
    echo ""

    if (( session_count == 0 )); then
      echo -e "  ${DIM}No existing tmux sessions${NC}"
      echo ""
    else
      echo -e "  ${DIM}Sessions:${NC}"
      echo ""
    fi

    # Draw session list
    for (( i=0; i<session_count; i++ )); do
      local prefix="    "
      local status_badge=""

      if [[ "${statuses[$i]}" == "attached" ]]; then
        status_badge="${GREEN}● attached${NC}"
      else
        status_badge="${DIM}○ detached${NC}"
      fi

      if (( i == selected )); then
        echo -e "  ${BG_CYAN}${BOLD} ▸ ${names[$i]}${NC}  ${status_badge}"
        echo -e "  ${BG_DARK}    ${details[$i]}${NC}"
      else
        echo -e "  ${prefix}${names[$i]}  ${status_badge}"
        echo -e "  ${DIM}    ${details[$i]}${NC}"
      fi
      echo ""
    done

    # "New session" option
    if (( selected == session_count )); then
      echo -e "  ${BG_CYAN}${BOLD} + New session${NC}"
    else
      echo -e "  ${DIM}  + New session${NC}"
    fi

    echo ""
    echo -e "  ${DIM}↑/↓ navigate · enter select · q quit${NC}"

    # Read input
    local key
    IFS= read -rsn1 key

    case "$key" in
      q|Q)
        tput cnorm 2>/dev/null || true
        echo ""
        exit 0
        ;;
      "")  # Enter
        break
        ;;
      $'\x1b')  # Escape sequence
        local seq
        IFS= read -rsn2 -t 0.1 seq || true
        case "$seq" in
          '[A')  # Up
            (( selected > 0 )) && selected=$((selected - 1))
            ;;
          '[B')  # Down
            (( selected < total_items - 1 )) && selected=$((selected + 1))
            ;;
        esac
        ;;
      k|K)  # vim up
        (( selected > 0 )) && selected=$((selected - 1))
        ;;
      j|J)  # vim down
        (( selected < total_items - 1 )) && selected=$((selected + 1))
        ;;
    esac
  done

  # Restore cursor
  tput cnorm 2>/dev/null || true

  # Handle selection
  if (( selected == session_count )); then
    create_new_session "$ip"
  else
    attach_session "$ip" "${names[$selected]}"
  fi
}

# --- Create new session ---
create_new_session() {
  local ip="$1"

  printf '\033[2J\033[H'
  echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}  ║          New tmux session                ║${NC}"
  echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════╝${NC}"
  echo ""

  tput cnorm 2>/dev/null || true

  local session_name=""
  echo -ne "  ${WHITE}Session name${NC} ${DIM}(default: claude)${NC}: "
  read -r session_name
  session_name="${session_name:-claude}"

  # Validate session name (tmux-safe: alphanumeric, dash, underscore, dot)
  if [[ ! "$session_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    err "Invalid session name. Use only letters, numbers, dash, underscore, dot."
    exit 1
  fi

  echo ""
  echo -e "  ${GREEN}▸${NC} Connecting to ${BOLD}$session_name${NC}..."
  echo ""

  # Use tmux new-session -A to create-or-attach
  exec vm_ssh -t "agentbox@$ip" "tmux new-session -A -s '$session_name'"
}

# --- Attach to existing session ---
attach_session() {
  local ip="$1"
  local name="$2"

  printf '\033[2J\033[H'
  echo -e "  ${GREEN}▸${NC} Attaching to ${BOLD}$name${NC}..."
  echo ""

  exec vm_ssh -t "agentbox@$ip" "tmux attach -t '$name'"
}

# --- Main ---
main() {
  local ip
  ip="$(get_server_ip)"

  # Quick connectivity check
  if ! vm_ssh -o ConnectTimeout=5 -o BatchMode=yes "agentbox@$ip" "true" &>/dev/null; then
    err "Cannot reach VM at $ip. Is it running?"
    exit 1
  fi

  run_selector "$ip"
}

main "$@"

#!/usr/bin/env bash
#
# connect.sh — Interactive 2-step TUI for workspace + tmux session management.
# Step 1: Select or create a workspace (Docker container).
# Step 2: Select or create a tmux session inside that workspace.
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

# --- Format timestamp to human-readable ---
format_time() {
  local ts="$1"
  if date --version &>/dev/null 2>&1; then
    date -d "@$ts" "+%b %d %H:%M" 2>/dev/null || echo "unknown"
  else
    date -r "$ts" "+%b %d %H:%M" 2>/dev/null || echo "unknown"
  fi
}

# ============================================================================
# Image freshness check + auto-rebuild
# ============================================================================

# git hash of the docker/workspace tree — used to detect stale images on the VM
workspace_git_hash() {
  # Hash actual file contents so uncommitted changes are detected
  find "$PROJECT_DIR/docker/workspace" -type f | sort | \
    xargs sha256sum 2>/dev/null | sha256sum | awk '{print $1}'
}

# Rebuild the workspace image on the VM if it's behind the local docker/workspace tree
ensure_image_fresh() {
  local ip="$1"

  local local_hash remote_hash
  local_hash="$(workspace_git_hash)"
  remote_hash="$(vm_ssh "agentbox@$ip" \
    "docker inspect agent-dev-space:latest --format '{{index .Config.Labels \"ads.workspace.git-hash\"}}'" \
    2>/dev/null || echo "")"

  if [[ "$local_hash" == "$remote_hash" ]]; then
    return 0
  fi

  echo -e "\n  ${YELLOW}▸${NC} Workspace image is outdated — rebuilding on VM..."
  echo -e "  ${DIM}(local: ${local_hash:0:8}  vm: ${remote_hash:0:8})${NC}"
  echo ""

  tar -C "$PROJECT_DIR/docker" -cf - workspace 2>/dev/null | \
    vm_ssh "agentbox@$ip" \
      "tar -C /tmp -xf - && rm -rf /tmp/docker-workspace && mv /tmp/workspace /tmp/docker-workspace"

  local build_log
  if ! build_log=$(vm_ssh "agentbox@$ip" \
    "docker build --label ads.workspace.git-hash=${local_hash} \
      -t agent-dev-space:latest /tmp/docker-workspace 2>&1"); then
    echo -e "  ${RED}✗${NC} Image build failed:"
    echo "$build_log" | tail -20 | sed 's/^/    /'
    return 1
  fi

  echo -e "  ${GREEN}▸${NC} Image updated (${local_hash:0:8})."
  echo ""
}

# ============================================================================
# STEP 1: Workspace selection
# ============================================================================

# --- Fetch workspace list from VM ---
fetch_workspaces() {
  local ip="$1"
  # Returns: container_name|state|size
  vm_ssh "agentbox@$ip" \
    "docker ps -a --filter 'name=^ws-' --format '{{.Names}}|{{.State}}|{{.Size}}'" 2>/dev/null \
    || true
}

# --- Find next free port base ---
next_port_base() {
  local ip="$1"
  # Ask Docker directly which host ports are already bound (running containers only)
  local used_ports
  used_ports="$(vm_ssh "agentbox@$ip" \
    "docker ps --format '{{.Ports}}' 2>/dev/null | grep -oE '[0-9]+->[0-9]' | cut -d- -f1" \
    || true)"

  local base=3000
  while true; do
    local ssh_port=$((base + 22))
    # Conflict if the SSH port or the start of the app range is already bound
    if echo "$used_ports" | grep -qE "^(${base}|${ssh_port})$" 2>/dev/null; then
      base=$((base + 100))
    else
      break
    fi
  done
  echo "$base"
}

# --- Create a new workspace ---
create_workspace() {
  local ip="$1"

  printf '\033[2J\033[H'
  echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}  ║          New workspace                   ║${NC}"
  echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════╝${NC}"
  echo ""

  tput cnorm 2>/dev/null || true

  local ws_name=""
  echo -ne "  ${WHITE}Workspace name${NC}: "
  read -r ws_name

  if [[ -z "$ws_name" ]]; then
    err "Name cannot be empty."
    sleep 1
    return 1
  fi

  # Validate name
  if [[ ! "$ws_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    err "Invalid name. Use only letters, numbers, dash, underscore, dot."
    sleep 1
    return 1
  fi

  # Check if workspace already exists
  if vm_ssh "agentbox@$ip" "docker inspect ws-${ws_name}" &>/dev/null 2>&1; then
    err "Workspace '${ws_name}' already exists."
    sleep 1
    return 1
  fi

  # Ensure image is up to date before creating a container from it
  ensure_image_fresh "$ip"

  echo ""
  echo -e "  ${DIM}Creating workspace...${NC}"

  local port_base
  port_base="$(next_port_base "$ip")"
  local ssh_port=$((port_base + 22))

  local create_err
  if ! create_err=$(vm_ssh "agentbox@$ip" "docker run -d \
    --name ws-${ws_name} \
    --hostname ${ws_name} \
    --restart unless-stopped \
    --label ads.port-base=${port_base} \
    -v /home/agentbox/.config/workspace/.ssh:/home/agentbox/.ssh:ro \
    -v /home/agentbox/.ssh-agent:/home/agentbox/.ssh-agent \
    -p ${ssh_port}:22 \
    agent-dev-space:latest" 2>&1); then
    err "Failed to create container: $create_err"
    vm_ssh "agentbox@$ip" "docker rm -f ws-${ws_name}" &>/dev/null || true
    sleep 2
    return 1
  fi

  if ! vm_ssh "agentbox@$ip" \
    "docker cp /home/agentbox/.config/workspace/.gitconfig ws-${ws_name}:/home/agentbox/.gitconfig && \
    docker exec ws-${ws_name} chown agentbox:agentbox /home/agentbox/.gitconfig && \
    docker cp /home/agentbox/.config/workspace/.claude ws-${ws_name}:/home/agentbox/.claude-init && \
    docker exec ws-${ws_name} bash -c 'cp -rn /home/agentbox/.claude-init/* /home/agentbox/.claude/ 2>/dev/null; rm -rf /home/agentbox/.claude-init; chown -R agentbox:agentbox /home/agentbox/.claude'" \
    >/dev/null 2>&1; then
    err "Container started but config setup failed. Container left running — select it from the TUI."
    sleep 2
    return 1
  fi

  echo -e "  ${GREEN}▸${NC} Workspace ${BOLD}${ws_name}${NC} created (SSH port ${ssh_port})"
  echo -e "  ${GREEN}▸${NC} Connecting to tmux session ${BOLD}claude${NC}..."
  echo ""

  # Attach directly to a new tmux session
  exec ssh "${SSH_OPTS[@]}" -t "agentbox@$ip" \
    "docker exec -it ws-${ws_name} tmux new-session -s claude"
}

# --- Workspace selector TUI ---
run_workspace_selector() {
  local ip="$1"

  # Hide cursor
  tput civis 2>/dev/null || true
  trap 'tput cnorm 2>/dev/null; tput sgr0 2>/dev/null' EXIT INT TERM

  while true; do
    local raw_workspaces
    raw_workspaces="$(fetch_workspaces "$ip")"

    # Parse workspaces into arrays
    local -a ws_names=()
    local -a ws_states=()
    local -a ws_sizes=()

    while IFS='|' read -r name state size; do
      [[ -z "$name" ]] && continue
      # Strip ws- prefix for display
      ws_names+=("${name#ws-}")
      ws_states+=("$state")
      # Show just the writable size (before " (virtual ...)")
      ws_sizes+=("${size%% (*}")
    done <<< "$raw_workspaces"

    local ws_count=${#ws_names[@]}
    local total_items=$((ws_count + 1))  # +1 for "New workspace"
    local selected=0

    # Inner TUI loop (redraws on navigation, breaks on action)
    while true; do
      printf '\033[2J\033[H'

      # Header
      echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════╗${NC}"
      echo -e "${BOLD}${CYAN}  ║       Agent Dev Space · Connect         ║${NC}"
      echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════╝${NC}"
      echo ""
      echo -e "  ${DIM}Server: ${NC}${WHITE}$ip${NC}"
      echo ""

      if (( ws_count == 0 )); then
        echo -e "  ${DIM}No workspaces yet${NC}"
        echo ""
      else
        echo -e "  ${DIM}Workspaces:${NC}"
        echo ""
      fi

      # Draw workspace list
      for (( i=0; i<ws_count; i++ )); do
        local status_badge=""
        if [[ "${ws_states[$i]}" == "running" ]]; then
          status_badge="${GREEN}● running${NC}"
        else
          status_badge="${DIM}○ stopped${NC}"
        fi

        if (( i == selected )); then
          echo -e "  ${BG_CYAN}${BOLD} ▸ ${ws_names[$i]}${NC}  ${status_badge}  ${DIM}${ws_sizes[$i]}${NC}"
        else
          echo -e "    ${ws_names[$i]}  ${status_badge}  ${DIM}${ws_sizes[$i]}${NC}"
        fi
        echo ""
      done

      # "New workspace" option
      if (( selected == ws_count )); then
        echo -e "  ${BG_CYAN}${BOLD} + New workspace${NC}"
      else
        echo -e "  ${DIM}  + New workspace${NC}"
      fi

      echo ""
      echo -e "  ${DIM}↑/↓ navigate · enter select · s stop/start · d destroy · q quit${NC}"

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
          if (( selected == ws_count )); then
            # New workspace
            tput cnorm 2>/dev/null || true
            create_workspace "$ip" || true
            tput civis 2>/dev/null || true
            break  # refresh workspace list
          elif [[ "${ws_states[$selected]}" != "running" ]]; then
            # Auto-start stopped workspace
            printf '\033[2J\033[H'
            echo -e "  ${YELLOW}Starting workspace ${BOLD}${ws_names[$selected]}${NC}${YELLOW}...${NC}"
            vm_ssh "agentbox@$ip" "docker start ws-${ws_names[$selected]}" >/dev/null
            sleep 1
          fi
          # Enter session selector for this workspace
          if [[ "${ws_states[$selected]}" == "running" ]] || \
             vm_ssh "agentbox@$ip" "docker inspect -f '{{.State.Running}}' ws-${ws_names[$selected]}" 2>/dev/null | grep -q true; then
            tput cnorm 2>/dev/null || true
            run_session_selector "$ip" "${ws_names[$selected]}"
            tput civis 2>/dev/null || true
            break  # refresh workspace list after returning from sessions
          fi
          ;;
        s|S)  # Stop/start toggle
          if (( selected < ws_count )); then
            if [[ "${ws_states[$selected]}" == "running" ]]; then
              printf '\033[2J\033[H'
              echo -e "  ${YELLOW}Stopping ${BOLD}${ws_names[$selected]}${NC}${YELLOW}...${NC}"
              vm_ssh "agentbox@$ip" "docker stop ws-${ws_names[$selected]}" >/dev/null
            else
              printf '\033[2J\033[H'
              echo -e "  ${YELLOW}Starting ${BOLD}${ws_names[$selected]}${NC}${YELLOW}...${NC}"
              vm_ssh "agentbox@$ip" "docker start ws-${ws_names[$selected]}" >/dev/null
            fi
            break  # refresh workspace list
          fi
          ;;
        d|D)  # Destroy
          if (( selected < ws_count )); then
            tput cnorm 2>/dev/null || true
            printf '\033[2J\033[H'
            echo -e "  ${RED}Destroy workspace ${BOLD}${ws_names[$selected]}${NC}${RED}?${NC}"
            echo -e "  ${DIM}This deletes all data inside the workspace.${NC}"
            echo ""
            echo -ne "  Type ${BOLD}yes${NC} to confirm: "
            local confirm
            read -r confirm
            if [[ "$confirm" == "yes" ]]; then
              echo ""
              echo -e "  ${RED}Destroying...${NC}"
              vm_ssh "agentbox@$ip" "docker rm -f ws-${ws_names[$selected]}" >/dev/null
            fi
            tput civis 2>/dev/null || true
            break  # refresh workspace list
          fi
          ;;
        $'\x1b')  # Escape sequence
          local seq
          IFS= read -rsn2 -t 0.1 seq || true
          case "$seq" in
            '[A')  (( selected > 0 )) && selected=$((selected - 1)) ;;
            '[B')  (( selected < total_items - 1 )) && selected=$((selected + 1)) ;;
          esac
          ;;
        k|K)  (( selected > 0 )) && selected=$((selected - 1)) ;;
        j|J)  (( selected < total_items - 1 )) && selected=$((selected + 1)) ;;
      esac
    done
  done
}

# ============================================================================
# STEP 2: tmux session selection (inside a workspace)
# ============================================================================

# --- Fetch tmux sessions from workspace container ---
fetch_sessions() {
  local ip="$1"
  local ws_name="$2"
  vm_ssh "agentbox@$ip" \
    "docker exec ws-${ws_name} tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_created}|#{?session_attached,attached,detached}' 2>/dev/null" \
    || true
}

# --- Create new session in workspace ---
create_new_session() {
  local ip="$1"
  local ws_name="$2"

  printf '\033[2J\033[H'
  echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}  ║          New tmux session                ║${NC}"
  echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${DIM}Workspace: ${NC}${WHITE}$ws_name${NC}"
  echo ""

  tput cnorm 2>/dev/null || true

  local session_name=""
  echo -ne "  ${WHITE}Session name${NC} ${DIM}(default: claude)${NC}: "
  read -r session_name
  session_name="${session_name:-claude}"

  if [[ ! "$session_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    err "Invalid session name. Use only letters, numbers, dash, underscore, dot."
    exit 1
  fi

  echo ""
  echo -e "  ${GREEN}▸${NC} Connecting to ${BOLD}$session_name${NC}..."
  echo ""

  exec ssh "${SSH_OPTS[@]}" -t "agentbox@$ip" \
    "docker exec -it ws-${ws_name} tmux new-session -A -s '${session_name}'"
}

# --- Attach to existing session in workspace ---
attach_session() {
  local ip="$1"
  local ws_name="$2"
  local name="$3"

  printf '\033[2J\033[H'
  echo -e "  ${GREEN}▸${NC} Attaching to ${BOLD}$name${NC} in workspace ${BOLD}$ws_name${NC}..."
  echo ""

  exec ssh "${SSH_OPTS[@]}" -t "agentbox@$ip" \
    "docker exec -it ws-${ws_name} tmux attach -t '${name}'"
}

# --- Session selector TUI ---
run_session_selector() {
  local ip="$1"
  local ws_name="$2"

  while true; do  # outer loop — refreshes session list
    local raw_sessions
    raw_sessions="$(fetch_sessions "$ip" "$ws_name")"

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
    local total_items=$((session_count + 2))  # +1 for "New session", +1 for "Back"
    local selected=0
    local action=""

    tput civis 2>/dev/null || true

    while true; do  # inner loop — TUI navigation
    printf '\033[2J\033[H'

    # Header
    echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}  ║       Agent Dev Space · Connect         ║${NC}"
    echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${DIM}Workspace: ${NC}${WHITE}$ws_name${NC}  ${GREEN}● running${NC}"
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
        echo -e "    ${names[$i]}  ${status_badge}"
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

    # "Back" option
    if (( selected == session_count + 1 )); then
      echo -e "  ${BG_CYAN}${BOLD} ← Back${NC}"
    else
      echo -e "  ${DIM}  ← Back${NC}"
    fi

    echo ""
    echo -e "  ${DIM}↑/↓ navigate · enter select · x kill · q quit${NC}"

    # Read input
    local key
    IFS= read -rsn1 key

    case "$key" in
      q|Q)
        tput cnorm 2>/dev/null || true
        echo ""
        exit 0
        ;;
      x|X)  # Kill session
        if (( selected < session_count )); then
          vm_ssh "agentbox@$ip" \
            "docker exec ws-${ws_name} tmux kill-session -t '${names[$selected]}'" &>/dev/null || true
          break  # refresh session list
        fi
        ;;
      "")  # Enter
        if (( selected == session_count + 1 )); then
          # Back to workspace selector
          action="back"
          break
        elif (( selected == session_count )); then
          # New session
          tput cnorm 2>/dev/null || true
          create_new_session "$ip" "$ws_name"
        else
          # Attach to existing session
          tput cnorm 2>/dev/null || true
          attach_session "$ip" "$ws_name" "${names[$selected]}"
        fi
        ;;
      $'\x1b')  # Escape sequence
        local seq
        IFS= read -rsn2 -t 0.1 seq || true
        case "$seq" in
          '[A')  (( selected > 0 )) && selected=$((selected - 1)) ;;
          '[B')  (( selected < total_items - 1 )) && selected=$((selected + 1)) ;;
          '')    action="back"; break ;;  # Plain Escape = back
        esac
        ;;
      k|K)  (( selected > 0 )) && selected=$((selected - 1)) ;;
      j|J)  (( selected < total_items - 1 )) && selected=$((selected + 1)) ;;
    esac
    done  # end inner TUI loop

    [[ "$action" == "back" ]] && return  # back to workspace selector
  done  # end outer refresh loop
}

# ============================================================================
# Main
# ============================================================================

main() {
  local ip
  ip="$(get_server_ip)"

  # Quick connectivity check
  if ! vm_ssh -o ConnectTimeout=5 -o BatchMode=yes "agentbox@$ip" "true" &>/dev/null; then
    err "Cannot reach VM at $ip. Is it running?"
    exit 1
  fi

  run_workspace_selector "$ip"
}

main "$@"

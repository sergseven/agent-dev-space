#!/usr/bin/env bash
# test-workspace-image.sh — Smoke-test the workspace Docker image.
# Runs a temporary container and checks every expected tool/feature.
# Exit code 0 = all pass, non-zero = at least one failure.
set -euo pipefail

IMAGE="${1:-agent-dev-space:latest}"
CONTAINER="ads-test-$$"
PASS=0
FAIL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL+1)); }

run() {
  # Run a command as agentbox inside the test container (interactive bash, login)
  docker exec "$CONTAINER" sudo -u agentbox bash -ic "$1" 2>/dev/null
}

echo -e "\n${BOLD}Testing image: ${IMAGE}${NC}\n"

# Start container
docker run -d --name "$CONTAINER" "$IMAGE" >/dev/null
sleep 4  # wait for entrypoint (sshd start)

trap 'docker rm -f "$CONTAINER" >/dev/null 2>&1' EXIT

# --- System tools ---
echo "System tools:"
run "git --version"        >/dev/null && pass "git"           || fail "git"
run "curl --version"       >/dev/null && pass "curl"          || fail "curl"
run "jq --version"         >/dev/null && pass "jq"            || fail "jq"
run "yq --version"         >/dev/null && pass "yq"            || fail "yq"
run "tmux -V"              >/dev/null && pass "tmux"          || fail "tmux"
run "gh --version"         >/dev/null && pass "gh"            || fail "gh"

# --- Dev tools ---
echo "Dev tools:"
run "node --version"       >/dev/null && pass "node (system)" || fail "node (system)"
run "task --version"       >/dev/null && pass "task"          || fail "task"
run "code --version"       >/dev/null && pass "code (vscode)" || fail "code (vscode)"

# --- asdf ---
echo "asdf:"
ASDF_VER=$(run "asdf version" 2>/dev/null || true)
if echo "$ASDF_VER" | grep -q "^v0\.18"; then
  pass "asdf v0.18.x (${ASDF_VER})"
else
  fail "asdf v0.18.x (got: ${ASDF_VER:-not found})"
fi

for plugin in nodejs java gradle cmake ollama android-sdk; do
  run "asdf plugin list" 2>/dev/null | grep -qx "$plugin" \
    && pass "asdf plugin: $plugin" || fail "asdf plugin: $plugin"
done

# --- SSH daemon ---
echo "SSH:"
run "pgrep sshd" >/dev/null && pass "sshd running" || fail "sshd running"
run "test -f /etc/ssh/sshd_config.d/workspace.conf" && pass "sshd config" || fail "sshd config"

# --- Entrypoint correctness ---
echo "Entrypoint:"
run "test -x /usr/local/bin/entrypoint.sh" && pass "entrypoint.sh executable" || fail "entrypoint.sh executable"
run "grep -q 'mkdir.*run/sshd' /usr/local/bin/entrypoint.sh" && pass "/run/sshd created" || fail "/run/sshd created"

# --- Environment ---
echo "Environment:"
run "test -f /etc/profile.d/asdf-java-home.sh" && pass "JAVA_HOME profile.d" || fail "JAVA_HOME profile.d"
run 'echo $LANG' 2>/dev/null | grep -q "en_US.UTF-8" && pass "locale UTF-8"  || fail "locale UTF-8"
run 'echo $TERM' 2>/dev/null | grep -q "xterm"       && pass "TERM set"      || fail "TERM set"

# --- cd hook ---
echo "Shell hooks:"
run 'type cd' 2>/dev/null | grep -q "function" && pass "cd auto-install hook" || fail "cd auto-install hook"

# --- Summary ---
TOTAL=$((PASS+FAIL))
echo ""
if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All ${TOTAL} checks passed.${NC}"
else
  echo -e "${RED}${BOLD}${FAIL}/${TOTAL} checks failed.${NC}"
  exit 1
fi

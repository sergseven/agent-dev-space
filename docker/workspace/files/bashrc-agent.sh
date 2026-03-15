# --- SSH agent forwarding ---
# In containers: agent socket is mounted at ~/.ssh-agent/agent.sock via socat on host
# On host: socat block in host .bashrc handles the forwarding
if [ -z "$SSH_AUTH_SOCK" ] && [ -S "$HOME/.ssh-agent/agent.sock" ]; then
    export SSH_AUTH_SOCK="$HOME/.ssh-agent/agent.sock"
fi

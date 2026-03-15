# --- SSH agent forwarding through tmux ---
# Update stable symlink to current SSH agent socket on each login.
# Processes inside tmux use the symlink, which always points to the live socket.
if [ -n "$SSH_AUTH_SOCK" ] && [ "$SSH_AUTH_SOCK" != "$HOME/.ssh/agent.sock" ]; then
    ln -sf "$SSH_AUTH_SOCK" "$HOME/.ssh/agent.sock"
    export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"
fi

# --- SSH agent forwarding ---
# In containers: agent socket is mounted at ~/.ssh-agent/agent.sock via socat on host
# On host: socat block in host .bashrc handles the forwarding
if [ -z "$SSH_AUTH_SOCK" ] && [ -S "$HOME/.ssh-agent/agent.sock" ]; then
    export SSH_AUTH_SOCK="$HOME/.ssh-agent/agent.sock"
fi

# --- JAVA_HOME (asdf-java doesn't set it automatically) ---
if [ -f "${ASDF_DATA_DIR:-$HOME/.asdf}/plugins/java/set-java-home.bash" ]; then
    . "${ASDF_DATA_DIR:-$HOME/.asdf}/plugins/java/set-java-home.bash"
fi

# --- Auto-install asdf tools when entering a directory with .tool-versions ---
_asdf_auto_install() {
    if [ -f .tool-versions ]; then
        asdf install 2>/dev/null
    fi
}
cd() { builtin cd "$@" && _asdf_auto_install; }
# Run once on shell start in case we're already in a project dir
_asdf_auto_install

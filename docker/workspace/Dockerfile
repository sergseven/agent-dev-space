# Agent Dev Space — Workspace Image
# All dev tools baked in. Per-workspace config (SSH keys, gitconfig, Claude auth)
# is injected via bind mounts at container run time.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Cleanup helper — removes apt cache, docs, man pages, and other non-essential files
# Defined once, used in every apt layer to keep image small.
ENV CLEANUP="rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* \
    /usr/share/perl/*/pod /usr/share/perl5/*/pod /usr/share/info/* \
    /usr/share/python-wheels/* /var/cache/apt/archives/* /tmp/*"

# Layer 1: System packages + GitHub CLI (both apt-based, single update)
RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
      git curl wget build-essential jq tmux unzip htop \
      python3 python3-pip python3-venv \
      ca-certificates gnupg sudo && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update -qq && apt-get install -y -qq gh && \
    eval "$CLEANUP"

# Layer 2: Node.js LTS
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y -qq nodejs && \
    eval "$CLEANUP"

# Layer 3: VS Code CLI (for Remote Tunnels)
RUN curl -fsSL "https://code.visualstudio.com/sha/download?build=stable&os=cli-alpine-x64" \
      -o /tmp/vscode-cli.tar.gz && \
    tar -xzf /tmp/vscode-cli.tar.gz -C /usr/local/bin && \
    rm -f /tmp/vscode-cli.tar.gz

# Layer 4: Claude Code (changes most frequently)
RUN npm install -g @anthropic-ai/claude-code && \
    npm cache clean --force

# Layer 5: agentbox user (UID 1000 — matches host user for bind mount permissions)
# Ubuntu 24.04 has a default 'ubuntu' user at UID 1000 — remove it first
RUN userdel -r ubuntu 2>/dev/null || true && \
    useradd -m -s /bin/bash -u 1000 agentbox && \
    echo "agentbox ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agentbox && \
    chmod 0440 /etc/sudoers.d/agentbox

# Layer 6: tmux config + bashrc SSH agent forwarding + mount point dirs
COPY files/tmux.conf /home/agentbox/.tmux.conf
COPY files/bashrc-agent.sh /tmp/bashrc-agent.sh
RUN cat /tmp/bashrc-agent.sh /home/agentbox/.bashrc > /tmp/.bashrc.new && \
    mv /tmp/.bashrc.new /home/agentbox/.bashrc && \
    rm /tmp/bashrc-agent.sh && \
    mkdir -p /home/agentbox/.ssh /home/agentbox/.claude /home/agentbox/projects && \
    chown -R agentbox:agentbox /home/agentbox

USER agentbox
WORKDIR /home/agentbox
CMD ["sleep", "infinity"]

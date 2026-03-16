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
      git curl wget build-essential jq tmux unzip htop openssh-client openssh-server locales \
      python3 python3-pip python3-venv \
      ca-certificates gnupg sudo && \
    sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen && locale-gen && \
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

# Layer 3: yq (YAML processor — needed by asdf android-sdk plugin)
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" -o /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

# Layer 3b: Taskfile (task runner)
RUN curl -fsSL https://taskfile.dev/install.sh | sh -s -- -d -b /usr/local/bin && \
    task --version

# Layer 4: VS Code CLI (for Remote Tunnels)
RUN curl -fsSL "https://code.visualstudio.com/sha/download?build=stable&os=cli-alpine-x64" \
      -o /tmp/vscode-cli.tar.gz && \
    tar -xzf /tmp/vscode-cli.tar.gz -C /usr/local/bin && \
    rm -f /tmp/vscode-cli.tar.gz

# Layer 4: agentbox user (UID 1000 — matches host user for bind mount permissions)
# Ubuntu 24.04 has a default 'ubuntu' user at UID 1000 — remove it first
RUN userdel -r ubuntu 2>/dev/null || true && \
    useradd -m -s /bin/bash -u 1000 agentbox && \
    echo "agentbox ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agentbox && \
    chmod 0440 /etc/sudoers.d/agentbox

# Layer 5: asdf v0.18.1 Go binary + plugins
# Binary installed system-wide; plugin/shim data lives in ASDF_DATA_DIR per user.
RUN curl -fsSL "https://github.com/asdf-vm/asdf/releases/download/v0.18.1/asdf-v0.18.1-linux-amd64.tar.gz" \
    | tar -xz -C /usr/local/bin && \
    asdf version

USER agentbox
ENV ASDF_DATA_DIR=/home/agentbox/.asdf
ENV PATH="/home/agentbox/.asdf/shims:${PATH}"
RUN echo '. <(asdf completion bash 2>/dev/null)' >> ~/.bashrc && \
    asdf plugin add nodejs      https://github.com/asdf-vm/asdf-nodejs.git && \
    asdf plugin add java        https://github.com/halcyon/asdf-java.git && \
    asdf plugin add gradle      https://github.com/rfrancis/asdf-gradle.git && \
    asdf plugin add cmake       https://github.com/srivathsanmurali/asdf-cmake.git && \
    asdf plugin add ollama      https://github.com/virtualstaticvoid/asdf-ollama.git && \
    asdf plugin add android-sdk https://github.com/arcticShadow/asdf-android.git
USER root

# JAVA_HOME for all session types (login shells, IDE SSH sessions, etc.)
# Sourced via /etc/profile → /etc/profile.d, so it works without .bashrc.
RUN echo '. "$ASDF_DATA_DIR/plugins/java/set-java-home.bash" 2>/dev/null || true' \
    > /etc/profile.d/asdf-java-home.sh && \
    chmod 644 /etc/profile.d/asdf-java-home.sh

# Layer 6: Claude Code — native installer
USER agentbox
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV TERM=xterm-256color
USER root

# Layer 6: tmux config + bashrc SSH agent forwarding + mount point dirs
COPY files/tmux.conf /home/agentbox/.tmux.conf
COPY files/bashrc-agent.sh /tmp/bashrc-agent.sh
COPY files/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN cat /tmp/bashrc-agent.sh /home/agentbox/.bashrc > /tmp/.bashrc.new && \
    mv /tmp/.bashrc.new /home/agentbox/.bashrc && \
    rm /tmp/bashrc-agent.sh && \
    chmod +x /usr/local/bin/entrypoint.sh && \
    mkdir -p /home/agentbox/.ssh /home/agentbox/.ssh-agent /home/agentbox/.claude /home/agentbox/projects && \
    chown -R agentbox:agentbox /home/agentbox

USER agentbox
WORKDIR /home/agentbox
CMD ["/usr/local/bin/entrypoint.sh"]

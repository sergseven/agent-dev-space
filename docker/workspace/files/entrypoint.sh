#!/bin/bash
# Workspace container entrypoint.
# Generates SSH host keys (if first run) and starts sshd before handing off.

# Generate host keys idempotently
sudo ssh-keygen -A 2>/dev/null || true

# Disable password auth, allow only key-based SSH
sudo bash -c 'cat > /etc/ssh/sshd_config.d/workspace.conf << EOF
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM no
PrintMotd no
EOF'

# Start SSH daemon
sudo /usr/sbin/sshd

exec sleep infinity

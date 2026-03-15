#!/bin/bash
set -e

# Set openclaw user password from env var
if [ -n "$OPENCLAW_PASSWORD" ]; then
    echo "openclaw:$OPENCLAW_PASSWORD" | chpasswd
fi

# Ensure .ssh directory exists (bind mount may overwrite home)
mkdir -p /home/openclaw/.ssh
chown openclaw:openclaw /home/openclaw /home/openclaw/.ssh
chmod 700 /home/openclaw/.ssh

# Copy authorized_keys if provided and non-empty
if [ -f /tmp/authorized_keys ] && [ -s /tmp/authorized_keys ]; then
    cp /tmp/authorized_keys /home/openclaw/.ssh/authorized_keys
    chown openclaw:openclaw /home/openclaw/.ssh/authorized_keys
    chmod 600 /home/openclaw/.ssh/authorized_keys
fi

exec /usr/sbin/sshd -D -e

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

# Start OpenClaw gateway in background as openclaw user
mkdir -p /tmp/openclaw
chown openclaw:openclaw /tmp/openclaw
su - openclaw -c 'export PATH="/home/openclaw/.npm-global/bin:$PATH" && openclaw gateway --port 18789 --bind lan >> /tmp/openclaw/gateway.log 2>&1 &'

exec /usr/sbin/sshd -D -e

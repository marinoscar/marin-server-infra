# OpenClaw Setup — `openclaw.marin.cr`

## Overview

OpenClaw is a personal AI assistant ([openclaw.ai](https://openclaw.ai/)). It runs inside an SSH-accessible Docker container with Node.js 24, pnpm, build tools, and Python 3 pre-installed. SSH access is direct on port 2222 (not proxied through Nginx). The Nginx config only serves an informational landing page.

## Architecture

```
ssh -p 2222 openclaw@openclaw.marin.cr → port 2222 → openclaw-ssh container (port 22)
openclaw.marin.cr (443) → Nginx → plain text landing page with SSH instructions
```

## File locations

```
/opt/infra/apps/openclaw/
├── Dockerfile           # Ubuntu 24.04 + Node.js 24 + pnpm + build tools
├── entrypoint.sh        # Sets password, configures SSH keys, starts sshd
├── compose.yml          # Docker Compose definition
├── .env                 # Password (OPENCLAW_PASSWORD=..., not committed)
├── authorized_keys      # SSH public keys for key-based auth
└── data/home/           # Persisted home directory (not committed)
```

Nginx config: `/opt/infra/proxy/nginx/conf.d/openclaw.marin.cr.conf`

## Container details

| Container | Purpose | Port |
|-----------|---------|------|
| `openclaw-ssh` | SSH dev environment | 2222 → 22 |

The container includes:
- **Node.js 24** (via NodeSource)
- **pnpm** (latest, via corepack)
- **build-essential**, gcc, g++, make, cmake
- **Python 3**, pip
- **git**, curl, wget, nano, sudo

Non-root user `openclaw` has passwordless sudo access.

## Common operations

```bash
cd /opt/infra/apps/openclaw

# Start/restart
docker compose up -d
docker compose restart

# Rebuild (after Dockerfile or entrypoint changes)
docker compose up -d --build

# View logs
docker logs --tail 50 openclaw-ssh

# SSH into the container
ssh -p 2222 openclaw@openclaw.marin.cr
```

## Configuration

### Password

The SSH password is set via `OPENCLAW_PASSWORD` in `.env`. To change it:

```bash
nano /opt/infra/apps/openclaw/.env
docker compose restart
```

### SSH keys

Add public keys to `/opt/infra/apps/openclaw/authorized_keys` (one per line). The entrypoint copies them into the container on startup. Restart after changes:

```bash
docker compose restart
```

### Home directory persistence

The user's home directory is bind-mounted to `./data/home/`. This persists installed tools, shell config, and project files across container rebuilds. The `data/` directory is git-ignored.

## Firewall

Port 2222 is open in UFW:

```bash
ufw allow 2222/tcp comment "OpenClaw SSH"
```

## Full rebuild from scratch

If recreating on a new server:

```bash
# 1. Create directory
mkdir -p /opt/infra/apps/openclaw

# 2. Copy Dockerfile, entrypoint.sh, compose.yml from repo
#    (these are committed to git)

# 3. Create .env with password
nano /opt/infra/apps/openclaw/.env
# Add: OPENCLAW_PASSWORD=<your-password>

# 4. Create authorized_keys (optional, can be empty)
touch /opt/infra/apps/openclaw/authorized_keys

# 5. Build and start
cd /opt/infra/apps/openclaw
docker compose up -d --build

# 6. Open firewall
ufw allow 2222/tcp comment "OpenClaw SSH"

# 7. Add DNS A record for openclaw.marin.cr pointing to server IP

# 8. Deploy nginx config (copy openclaw.marin.cr.conf to proxy/nginx/conf.d/)
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload

# 9. Issue TLS certificate (after DNS propagates)
docker run --rm \
  -v /opt/infra/proxy/letsencrypt:/etc/letsencrypt \
  -v /opt/infra/proxy/certbot-webroot:/var/www/certbot \
  certbot/certbot certonly --webroot \
  -w /var/www/certbot \
  -d openclaw.marin.cr \
  --agree-tos --no-eff-email

# 10. Add HTTPS server block to nginx config, reload

# 11. Install OpenClaw inside the container
ssh -p 2222 openclaw@openclaw.marin.cr
curl -fsSL https://openclaw.ai/install.sh | bash
# or: npm i -g openclaw
```

## Verification

```bash
# Container running
docker ps | grep openclaw

# SSH works locally
ssh -p 2222 openclaw@127.0.0.1

# SSH works externally
ssh -p 2222 openclaw@openclaw.marin.cr

# Tools available inside container
ssh -p 2222 openclaw@127.0.0.1 'node -v && pnpm -v && git --version && python3 --version'

# UFW rule active
ufw status | grep 2222
```

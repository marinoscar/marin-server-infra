# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Self-hosted Docker-based server infrastructure for deploying containerized applications on an Ubuntu VPS. Uses Nginx reverse proxy with TLS, Docker Compose for service orchestration, and shell scripts for automation. Root-operated by design.

## Architecture

```
/opt/infra (deployed location)
├── apps/           # Application stacks (one compose.yml each)
│   ├── marinapp/   # Custom full-stack app (Vite frontend + API)
│   ├── postgres/   # PostgreSQL 16 + pgAdmin
│   └── nextcloud/  # Nextcloud with S3 + Redis
├── proxy/          # Nginx reverse proxy (host network mode)
│   ├── nginx/conf.d/  # Virtual host configs
│   └── letsencrypt/   # TLS certificates (ignored)
├── shared/         # Utility scripts (cert renewal)
└── docs/           # Runbooks and setup guides
```

**Key Patterns:**
- Apps bind to `127.0.0.1:<port>`, proxied through Nginx
- Nginx runs in `network_mode: host` for VPS reliability
- `.env` files contain secrets (never committed)
- Main branch represents deployed state

## Common Operations

```bash
# Proxy management
cd /opt/infra/proxy
docker compose up -d
docker exec proxy-nginx nginx -t          # Validate config
docker exec proxy-nginx nginx -s reload   # Reload without downtime

# Application operations
cd /opt/infra/apps/<app>
docker compose up -d --build              # Start/rebuild
docker compose restart
docker logs --tail 100 <container>

# Certificate renewal (runs via cron)
/opt/infra/shared/renew-all-certs.sh

# MarinApp installation
/opt/infra/apps/marinapp/install-marinapp.sh
/opt/infra/apps/marinapp/restore-marinapp.sh  # From backup
```

## Critical Implementation Notes

1. **Vite Environment Variables:** Changing `.env` requires `docker compose build --no-cache web` - env vars are baked in at build time
2. **Install Script Pattern:** Must source `.env` before build:
   ```bash
   set -a
   . ./.env
   set +a
   docker compose build --no-cache web
   ```
3. **Certbot Path Normalization:** Renewal configs must use container paths (`/etc/letsencrypt`), not host paths - the renewal script handles this
4. **pgAdmin Volumes:** Use Docker named volumes, not bind mounts (permission issues)
5. **Nginx in Host Mode:** Cannot resolve Docker DNS; use `127.0.0.1` or `host.docker.internal`

## Operator Preferences

These preferences are documented in `docs/server-setup.md`:

- **Editor:** `nano` (not vim)
- **Commands:** Explicit, readable (no aliases or bash tricks)
- **Steps:** Small, verifiable with checks after each operation
- **Git:** Infrastructure changes committed; secrets/data never committed
- **Root user:** Intentional design; no sudo or non-root patterns
- **Clarity over cleverness:** Prefer explicit config to dynamic variables

## Services & Domains

| Service | Port (localhost) | Public URL |
|---------|------------------|------------|
| MarinApp Web | 3021 | app.marin.cr |
| MarinApp API | 5000 | api.marin.cr |
| Nextcloud | 8082 | cloud.marin.cr |
| pgAdmin | 5050 | pgadmin.marin.cr |
| Cockpit | 9090 | admin.marin.cr |
| Portainer | 9005 | portainer.marin.cr |
| Mattermost | 8065 | team.marin.cr |
| LibreChat | 3080 | chat.marin.cr |
| ShellKeep | 8323 | shellkeep.marin.cr |
| OpenClaw SSH | 2222 (SSH) | openclaw.marin.cr |
| PostgreSQL | 5432 | Direct (no proxy) |

## Verification Commands

```bash
# Check proxy health
curl -I https://domain.example.com

# Container status
docker ps
docker logs --tail 50 <container>

# Certificate expiry
openssl x509 -enddate -noout -in /opt/infra/proxy/letsencrypt/live/domain/fullchain.pem

# Network inspection
docker network inspect proxy
```

## Documentation

Detailed runbooks are in `docs/`:
- `server-setup.md` - Base infrastructure, UFW, Docker, architecture philosophy
- `postgresql-setup.md` - Database and pgAdmin setup
- `marinapp-setup.md` - Full-stack app deployment
- `nextcloud-setup.md` - File sync with S3 backend
- `cockpit-setup.md` - Admin UI with Basic Auth
- `portainer-setup.md` - Docker management UI with Authentik OAuth
- `certificate-renewal-setup.md` - TLS automation
- `crowdsec-setup.md` - Intrusion detection and prevention (host-level)
- `librechat-setup.md` - AI chat interface with multi-provider support
- `openclaw-setup.md` - SSH dev container for OpenClaw AI assistant

## SERVER.md Maintenance

`SERVER.md` is the user-facing landing page listing all installed apps with descriptions and access links. **When adding or removing an app/service, update `SERVER.md` accordingly** to keep it in sync with the Services & Domains table above.

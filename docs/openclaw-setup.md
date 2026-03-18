# OpenClaw Setup — `openclaw.marin.cr`

## Overview

OpenClaw is a personal AI assistant ([openclaw.ai](https://openclaw.ai/)). It runs inside an SSH-accessible Docker container with Node.js 24, pnpm, build tools, and Python 3 pre-installed. The OpenClaw Gateway starts automatically with the container and serves a web dashboard proxied through Nginx with Authentik forward auth. SSH access is direct on port 2222. OpenClaw is also connected to Mattermost as a bot (`@openclaw`) on `team.marin.cr`.

## Architecture

```
Browser → https://openclaw.marin.cr (443)
       → Nginx (TLS termination + Authentik forward auth)
       → 127.0.0.1:18789
       → openclaw-ssh container (OpenClaw Gateway, loopback)

SSH    → ssh -p 2222 openclaw@openclaw.marin.cr
       → port 2222
       → openclaw-ssh container (sshd, port 2222)

Mattermost → team.marin.cr → @openclaw bot
           → OpenClaw Gateway handles slash commands and interactions
```

The container runs with `network_mode: host`, sharing the host's network stack directly. Both SSH (port 2222) and the Gateway (port 18789) bind directly on the host. The gateway binds to loopback (`127.0.0.1`) so it is only reachable through nginx; SSH listens on all interfaces.

## File locations

```
/opt/infra/apps/openclaw/
├── Dockerfile           # Ubuntu 24.04 + Node.js 24 + pnpm + build tools + SSH
├── entrypoint.sh        # Sets password, configures SSH keys, starts gateway + sshd
├── compose.yml          # Docker Compose definition (host network mode)
├── .env                 # Password (OPENCLAW_PASSWORD=..., not committed)
├── authorized_keys      # SSH public keys for key-based auth (can be empty)
└── data/home/           # Persisted home directory (not committed, git-ignored)

/opt/infra/proxy/nginx/conf.d/
└── openclaw.marin.cr.conf   # Nginx reverse proxy + Authentik forward auth
```

## Container details

| Container | Purpose | Ports |
|-----------|---------|-------|
| `openclaw-ssh` | SSH server + OpenClaw Gateway | 2222 (SSH, all interfaces), 127.0.0.1:18789 (Gateway, loopback only) |

The container uses `network_mode: host` — there is no Docker port mapping. sshd listens on port 2222 directly (configured in `sshd_config`), and the gateway binds to `127.0.0.1:18789` via `--bind loopback`.

The container includes:
- **Node.js 24** (via NodeSource)
- **pnpm** (latest, via corepack)
- **build-essential**, gcc, g++, make, cmake
- **Python 3**, pip
- **git**, curl, wget, nano, sudo

Non-root user `openclaw` has passwordless sudo access. OpenClaw is installed globally via npm at `/home/openclaw/.npm-global/bin/openclaw`.

## Gateway

The OpenClaw Gateway starts automatically via the entrypoint script with `--bind loopback` (listens on `127.0.0.1` only). Because the container uses host networking, the gateway binds directly to the host's loopback interface. Nginx proxies external traffic to it.

Gateway config is stored in `/home/openclaw/.openclaw/openclaw.json` (persisted via the home directory bind mount).

Key gateway settings:
- `gateway.auth.mode`: `"none"` (no token required — Authentik handles auth at the nginx layer)
- `gateway.bind`: `"loopback"` (gateway only accessible via localhost)
- `gateway.controlUi.allowedOrigins`: `["https://openclaw.marin.cr"]`
- `gateway.controlUi.dangerouslyDisableDeviceAuth`: `true` (Authentik handles auth instead)

Settings no longer needed (were required with the old Docker bridge networking):
- `gateway.trustedProxies` — not needed because with host networking, nginx connects from `127.0.0.1` (loopback), which the gateway trusts by default.

Gateway logs: `/tmp/openclaw/gateway.log` (inside container, not persisted across restarts)

### Gateway authentication model

The gateway has its own token-based auth (`gateway.auth.mode: "token"`) that is required when binding to non-loopback interfaces (`--bind lan`). Since we use host networking and bind to loopback, we can set `gateway.auth.mode: "none"` which eliminates the need for tokens entirely. Authentik provides authentication at the nginx layer instead.

**Important**: If you ever switch back to `--bind lan`, the gateway will refuse to start without `gateway.auth.mode: "token"` and a `gateway.auth.token` value. The token must then be passed to the browser via the URL hash fragment (e.g., `https://openclaw.marin.cr/#token=<TOKEN>`). Use `openclaw dashboard --no-open` to see the current dashboard URL with token. The `--bind loopback` + `auth.mode: none` approach avoids this complexity entirely.

### Gateway startup details

The gateway takes approximately **60-70 seconds** to fully initialize. During startup it loads plugins (including the Mattermost integration), registers hooks, and connects to configured channels. The entrypoint starts the gateway as a background `nohup` process before starting sshd as the foreground process.

Since Docker containers do not run systemd, the gateway cannot use `openclaw gateway install` / `systemctl`. Instead, the entrypoint script handles autostart. If you need to manually restart the gateway inside the container:

```bash
# Find and kill the existing gateway process
kill $(cat /tmp/openclaw/*.pid 2>/dev/null) 2>/dev/null

# Start it again
export PATH="/home/openclaw/.npm-global/bin:$PATH"
openclaw gateway --port 18789 --bind loopback
```

## Authentication

### Web dashboard (Authentik)

Web access to the Control UI at `https://openclaw.marin.cr/` is protected by Authentik forward auth (same pattern as `admin.marin.cr` / Cockpit). OpenClaw's built-in device pairing is disabled since Authentik handles authentication at the nginx layer.

Authentik configuration (done in the admin UI at `https://auth.marin.cr/if/admin/`):
- **Provider**: Proxy Provider, mode "Forward auth (single application)", external host `https://openclaw.marin.cr`
- **Application**: name "OpenClaw", slug `openclaw`, linked to the proxy provider above
- **Outpost**: added to the existing outpost alongside other protected apps (admin.marin.cr, etc.)

### SSH access

SSH uses password authentication (set via `OPENCLAW_PASSWORD` in `.env`) and optionally public key authentication (via the `authorized_keys` file).

### Mattermost bot

The Mattermost integration requires separate pairing. When a user first messages the `@openclaw` bot, they receive a pairing code. The bot owner approves it:

```bash
# Inside the container
openclaw pairing approve mattermost <PAIRING_CODE>
```

## Mattermost integration

OpenClaw connects to Mattermost at `team.marin.cr` as the `@openclaw` bot. This is configured in `/home/openclaw/.openclaw/openclaw.json` (the Mattermost plugin section). Users can interact with OpenClaw by messaging the bot directly.

Known warnings (non-critical):
- "duplicate plugin id detected" — the Mattermost plugin appears in both bundled and extension form. Does not affect functionality.
- "interactions callbackUrl resolved to http://localhost:18789" — Mattermost button callbacks may not work since the gateway is inside a container. If needed, set `channels.mattermost.interactions.callbackBaseUrl` to `https://openclaw.marin.cr`.

## Common operations

```bash
cd /opt/infra/apps/openclaw

# Start/restart (gateway auto-starts via entrypoint)
docker compose up -d
docker compose restart

# Rebuild (after Dockerfile or entrypoint changes)
docker compose up -d --build

# View container logs (sshd output)
docker logs --tail 50 openclaw-ssh

# View gateway logs (inside container)
docker exec openclaw-ssh cat /tmp/openclaw/gateway.log | tail -50

# SSH into the container
ssh -p 2222 openclaw@openclaw.marin.cr

# Check gateway status (inside container)
openclaw gateway status

# List connected devices (inside container)
openclaw devices list

# Approve a Mattermost user (inside container)
openclaw pairing approve mattermost <CODE>
```

## Configuration

### SSH password

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

The user's home directory is bind-mounted to `./data/home/`. This persists:
- OpenClaw installation (`~/.npm-global/`)
- OpenClaw config and state (`~/.openclaw/`)
- Shell configuration (`~/.bashrc`, etc.)
- Any other files or projects

The `data/` directory is git-ignored. This means OpenClaw itself, its config, and all state survive container rebuilds. Only the base OS packages (Node.js, build tools, etc.) are reinstalled on rebuild.

### Gateway configuration

Gateway config lives at `~/.openclaw/openclaw.json` inside the container (persisted via bind mount). To modify settings:

```bash
# SSH into the container
ssh -p 2222 openclaw@openclaw.marin.cr

# Use the CLI to set values
openclaw config set <key> <value>

# Or edit directly
nano ~/.openclaw/openclaw.json
```

After config changes, restart the gateway (restart the container, or kill/restart the process manually).

## Nginx reverse proxy

The nginx config at `/opt/infra/proxy/nginx/conf.d/openclaw.marin.cr.conf` does three things:

1. **HTTP (port 80)**: Serves ACME challenges for cert renewal, redirects everything else to HTTPS
2. **HTTPS (port 443)**: Authentik forward auth, then proxies to `127.0.0.1:18789`
3. **WebSocket support**: Required for the gateway's real-time communication (uses `Upgrade` and `Connection` headers with the `$connection_upgrade` map)

## TLS certificate

Issued via Let's Encrypt / certbot using HTTP-01 challenge:

```bash
docker run --rm \
  -v /opt/infra/proxy/letsencrypt:/etc/letsencrypt \
  -v /opt/infra/proxy/webroot:/var/www/certbot \
  certbot/certbot certonly --webroot \
  -w /var/www/certbot \
  -d openclaw.marin.cr \
  --agree-tos --no-eff-email \
  -m admin@marin.cr
```

Auto-renewed by the existing `renew-all-certs.sh` cron job.

## Firewall

Port 2222 (SSH) is open in UFW. The gateway port (18789) is NOT open in UFW — it is bound to `127.0.0.1` only and accessed through the nginx proxy.

```bash
ufw allow 2222/tcp comment "OpenClaw SSH"
```

## Troubleshooting

### Gateway not starting after container restart

The entrypoint starts the gateway in the background. It takes ~60-70 seconds to initialize. Check the log:

```bash
docker exec openclaw-ssh cat /tmp/openclaw/gateway.log
```

If the log is empty or shows PATH errors, SSH in and start manually:

```bash
ssh -p 2222 openclaw@openclaw.marin.cr
export PATH="/home/openclaw/.npm-global/bin:$PATH"
openclaw gateway --port 18789 --bind loopback
```

### "gateway already running" error

A previous gateway process is still holding the port. Kill it first:

```bash
# Inside the container
kill $(cat /tmp/openclaw/*.pid 2>/dev/null) 2>/dev/null
# If that doesn't work, find and kill by port
kill $(fuser 18789/tcp 2>/dev/null) 2>/dev/null
# Then start again
openclaw gateway --port 18789 --bind loopback
```

### "gateway token mismatch" error in browser

The Control UI WebSocket connection is being rejected because of a token mismatch. This happens when:

1. **`gateway.auth.mode` is set to `"token"`** but the browser doesn't have the correct token. This is the most common cause after an OpenClaw update, which may regenerate the token.
2. **Browser has a stale token cached** in localStorage from a previous session.

**Current fix (recommended)**: The gateway is configured with `auth.mode: "none"` and `--bind loopback`. This eliminates tokens entirely since Authentik handles auth. Verify the config:

```bash
# Inside the container
openclaw config get gateway.auth
# Should show: { "mode": "none" }
```

If it shows `"mode": "token"`, fix it:

```bash
# Edit the config file directly (openclaw config set may not persist reliably)
nano ~/.openclaw/openclaw.json
# Change gateway.auth to: { "mode": "none" }
# Remove any "token" field
# Then restart the container
```

**If you must use token auth** (e.g., with `--bind lan`): get the current token URL with `openclaw dashboard --no-open`. The token is passed via **hash fragment** (`#token=...`), NOT query parameter (`?token=...`). Example: `https://openclaw.marin.cr/#token=abc123...`

**Important**: `openclaw config set` may not always persist changes to the JSON file reliably. If a config change doesn't take effect after restart, edit `~/.openclaw/openclaw.json` directly.

### "too many failed authentication attempts" error

The gateway rate-limits after repeated failed auth attempts. Restart the container to clear the rate limit:

```bash
cd /opt/infra/apps/openclaw
docker compose restart
# Wait ~70 seconds for gateway to initialize
```

### "Refusing to bind gateway to lan without auth" error

The gateway will not bind to non-loopback interfaces with `auth.mode: "none"`. Either:
- Use `--bind loopback` with `auth.mode: "none"` (current setup, recommended)
- Use `--bind lan` with `auth.mode: "token"` and set a `gateway.auth.token` value

### "pairing required" error in browser

This means the gateway's device auth is rejecting the connection. Fix:

```bash
# Disable device auth (Authentik handles auth)
openclaw config set gateway.controlUi.dangerouslyDisableDeviceAuth true
```

### "non-loopback Control UI requires allowedOrigins" error

The gateway is binding to a non-loopback address but doesn't know which origins to trust. Fix:

```bash
openclaw config set gateway.controlUi.allowedOrigins '["https://openclaw.marin.cr"]'
```

### HTTP 500 on openclaw.marin.cr

If the gateway is responding (test with `curl http://127.0.0.1:18789/`) but the browser shows 500, the issue is Authentik forward auth. Check:
- The Proxy Provider exists in Authentik with external host `https://openclaw.marin.cr`
- The Application exists and is linked to the provider
- The Application is added to the outpost
- The outpost is running (`docker ps | grep authentik`)

### systemd not available in container

Docker containers do not run systemd. The commands `openclaw gateway install` and `systemctl --user` will not work. The entrypoint script handles gateway autostart instead. Do not try to enable systemd services inside the container.

### Mattermost "access not configured" message

When a user first messages `@openclaw`, they receive a pairing code. The bot owner must approve it inside the container:

```bash
openclaw pairing approve mattermost <PAIRING_CODE>
```

This is a one-time approval per Mattermost user.

### Bind mount overwrites .ssh directory

The home directory bind mount (`./data/home:/home/openclaw`) replaces the container's `/home/openclaw` entirely, including `.ssh/`. The entrypoint handles this by creating `.ssh/` and copying `authorized_keys` on every startup. If SSH key auth stops working, check that the entrypoint is running correctly.

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

# 6. Open firewall for SSH (gateway port stays on loopback, no UFW needed)
ufw allow 2222/tcp comment "OpenClaw SSH"

# 7. Add DNS A record for openclaw.marin.cr pointing to server IP
#    (do this in your DNS provider, wait for propagation)

# 8. Deploy nginx config
#    Copy openclaw.marin.cr.conf to proxy/nginx/conf.d/
#    Initially deploy HTTP-only version (no HTTPS block) for cert issuance
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload

# 9. Issue TLS certificate (after DNS propagates)
docker run --rm \
  -v /opt/infra/proxy/letsencrypt:/etc/letsencrypt \
  -v /opt/infra/proxy/webroot:/var/www/certbot \
  certbot/certbot certonly --webroot \
  -w /var/www/certbot \
  -d openclaw.marin.cr \
  --agree-tos --no-eff-email \
  -m admin@marin.cr

# 10. Deploy full nginx config (with HTTPS + Authentik) and reload
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload

# 11. Install OpenClaw inside the container
ssh -p 2222 openclaw@openclaw.marin.cr
curl -fsSL https://openclaw.ai/install.sh | bash
openclaw onboard
# Follow the onboarding prompts to configure AI providers, etc.

# 12. Configure gateway for loopback access (no token needed)
openclaw config set gateway.auth.mode none
openclaw config set gateway.controlUi.allowedOrigins '["https://openclaw.marin.cr"]'
openclaw config set gateway.controlUi.dangerouslyDisableDeviceAuth true
# Verify the config was written (openclaw config set may not persist reliably):
cat ~/.openclaw/openclaw.json | python3 -c "import json,sys; c=json.load(sys.stdin); print(json.dumps(c['gateway']['auth'], indent=2))"
# Should show: { "mode": "none" }
# If not, edit ~/.openclaw/openclaw.json directly

# 13. Exit SSH and restart container to pick up gateway config
exit
cd /opt/infra/apps/openclaw
docker compose restart
# Wait ~70 seconds for gateway to initialize

# 14. Set up Authentik (in admin UI at https://auth.marin.cr/if/admin/)
#     a. Create Proxy Provider:
#        - Name: openclaw-proxy
#        - Authorization flow: select default
#        - Mode: Forward auth (single application)
#        - External host: https://openclaw.marin.cr
#     b. Create Application:
#        - Name: OpenClaw
#        - Slug: openclaw
#        - Provider: openclaw-proxy
#        - Launch URL: https://openclaw.marin.cr/
#     c. Edit existing outpost:
#        - Add "OpenClaw" to the applications list
#        - Save

# 15. Verify everything works
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18789/   # Should return 200
curl -I https://openclaw.marin.cr/                                 # Should redirect to Authentik
ssh -p 2222 openclaw@openclaw.marin.cr 'echo OK'                  # Should return OK

# 16. (Optional) Set up Mattermost bot
#     Configure the Mattermost plugin in ~/.openclaw/openclaw.json
#     When users message @openclaw, approve their pairing:
#     openclaw pairing approve mattermost <CODE>
```

## Verification

```bash
# Container running
docker ps | grep openclaw

# Gateway responding locally
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18789/

# SSH works locally
ssh -p 2222 openclaw@127.0.0.1

# SSH works externally
ssh -p 2222 openclaw@openclaw.marin.cr

# Public HTTPS (redirects to Authentik login)
curl -I https://openclaw.marin.cr/

# Tools available inside container
ssh -p 2222 openclaw@127.0.0.1 'node -v && pnpm -v && git --version && python3 --version'

# Gateway logs
docker exec openclaw-ssh cat /tmp/openclaw/gateway.log | tail -20

# TLS certificate expiry
openssl x509 -enddate -noout -in /opt/infra/proxy/letsencrypt/live/openclaw.marin.cr/fullchain.pem

# UFW rule active
ufw status | grep 2222
```

## Key learnings and gotchas

1. **Bind mount wipes container home**: Mounting `./data/home:/home/openclaw` replaces the entire home directory created in the Dockerfile. The entrypoint must recreate `.ssh/` on every boot.

2. **No systemd in containers**: Docker containers don't run systemd, so `openclaw gateway install` / `systemctl --user` won't work. Use the entrypoint to start the gateway as a background process instead.

3. **PATH not available in su context**: The entrypoint runs as root and uses `su - openclaw` to start the gateway. The openclaw binary is in `~/.npm-global/bin/` which isn't in the default PATH, so the entrypoint must explicitly set `PATH` before running `openclaw gateway`.

4. **Gateway needs ~60-70 seconds to start**: The gateway loads plugins, connects to Mattermost, and registers hooks. Don't expect it to respond immediately after container start. Wait at least 70 seconds before checking.

5. **Host networking eliminates Docker bridge issues**: The container uses `network_mode: host`, so nginx connects to the gateway via the host's `127.0.0.1` directly — no Docker bridge IPs involved. This means `gateway.trustedProxies` is not needed (loopback is trusted by default).

6. **Gateway auth mode and bind are linked**: `--bind loopback` allows `auth.mode: "none"` (no token). `--bind lan` requires `auth.mode: "token"` — the gateway refuses to start without it. The current setup uses loopback + no auth, with Authentik handling authentication at the nginx layer.

7. **Gateway token is passed via hash fragment, not query parameter**: If you ever need token auth, the URL format is `https://openclaw.marin.cr/#token=<TOKEN>` (hash `#`, not query `?`). The hash fragment is read client-side by the Control UI JavaScript. Use `openclaw dashboard --no-open` to get the current URL with token.

8. **`openclaw config set` may not persist reliably**: The CLI command reports success but the JSON file may not be updated. Always verify changes by reading `~/.openclaw/openclaw.json` directly. For critical config changes, edit the JSON file with `nano` instead.

9. **Device pairing vs Authentik**: OpenClaw has its own device pairing system for the Control UI. Since we use Authentik for authentication at the nginx layer, we disable OpenClaw's device auth (`dangerouslyDisableDeviceAuth: true`) to avoid double authentication.

10. **Mattermost pairing is separate**: Even with device auth disabled for the web UI, Mattermost users still need individual pairing approval via `openclaw pairing approve mattermost <CODE>`.

11. **sshd listens on port 2222 directly**: With host networking, there is no Docker port mapping. The Dockerfile configures sshd to listen on port 2222 via `sshd_config` (not the default port 22).

12. **Gateway port binding**: The gateway binds to `127.0.0.1:18789` via `--bind loopback`. With host networking, this is the host's loopback — it is only accessible through nginx, never directly from the internet. No UFW rule needed for port 18789.

13. **UID conflicts in Ubuntu 24.04**: The Ubuntu 24.04 base image already has UID 1000 assigned to the `ubuntu` user. The Dockerfile must not force `--uid 1000` when creating the `openclaw` user.

14. **HTTP-only nginx first for certbot**: When setting up from scratch, deploy an HTTP-only nginx config first (just ACME challenge + redirect). Issue the cert, then deploy the full HTTPS config. Nginx won't start if it references cert files that don't exist yet.

15. **Gateway config persists across rebuilds**: Since `~/.openclaw/` is inside the bind-mounted home directory, gateway configuration survives container rebuilds. You only need to configure `auth.mode`, `allowedOrigins`, etc. once.

16. **Gateway rate-limits failed auth attempts**: If the browser repeatedly fails to authenticate (e.g., stale token), the gateway will start rejecting with "too many failed authentication attempts". Restart the container to clear the rate limit.

17. **Use `nohup` in entrypoint for gateway process**: The gateway background process started via `su - openclaw -c '... &'` may not detach properly without `nohup`. The entrypoint uses `nohup` to ensure the gateway survives as a background process while sshd runs in the foreground.

# Server Setup (Ubuntu VPS) — `/opt/infra`

## Purpose

### Prerequisites

Before following or reusing this setup, the following prerequisites are assumed:

* An Ubuntu VPS with root SSH access
* A registered domain (e.g. `marin.cr`)
* DNS A records created for intended subdomains (e.g. `pgadmin.marin.cr` → VPS public IP)
* SSH key-based access to GitHub configured for this server
* Basic familiarity with Linux shell and Docker concepts

This document captures the current architecture and the exact setup steps completed so far for a self-hosted Ubuntu VPS platform using:

* **Root** as the operating user (intentionally)
* **Docker + Docker Compose** to run services
* A shared **reverse proxy** layer (Nginx) to front all apps
* **Git + GitHub** to version infrastructure configuration

The setup is designed to scale to multiple self-hosted applications with consistent patterns, minimal public exposure, and repeatable upgrades.

---

## High-level architecture

### Traffic and service boundaries

**Public Internet → VPS (UFW) → Nginx Reverse Proxy (Docker) → App containers (Docker)**

* **Only the reverse proxy** is intended to be publicly reachable for web apps (HTTP/HTTPS on ports **80/443**).
* Each application runs in its own Docker Compose stack and connects to a shared Docker network for proxy routing.
* Applications should generally be *internal-only* (no public port mappings) and accessed through Nginx.

### Current public ports

* **22/tcp** — SSH
* **80/tcp** — HTTP (Let's Encrypt HTTP-01 challenge + redirect to HTTPS)
* **443/tcp** — HTTPS (Nginx reverse proxy for all applications)
* **5432/tcp** — PostgreSQL (explicitly opened by request; note security implications below)

> **Note:** Exposing PostgreSQL to the open internet is high risk unless strongly hardened (TLS + `pg_hba.conf` restrictions + strong auth, ideally IP allowlisting). This document reflects the current state; hardening work can be added in a later phase.

### Currently deployed applications

| Application | Internal Port | Public URL | Documentation |
|-------------|---------------|------------|---------------|
| PostgreSQL | 5432 (public) | Direct access | `docs/postgresql-setup.md` |
| pgAdmin | 127.0.0.1:5050 | https://pgadmin.marin.cr | `docs/postgresql-setup.md` |
| Cockpit | 127.0.0.1:9090 | https://admin.marin.cr | `docs/cockpit-setup.md` |
| Nextcloud | 127.0.0.1:8082 | https://cloud.marin.cr | `docs/nextcloud-setup.md` |
| MarinApp Web | 127.0.0.1:3021 | https://app.marin.cr | `docs/marinapp-setup.md` |
| MarinApp API | 127.0.0.1:5000 | https://api.marin.cr | `docs/marinapp-setup.md` |
| n8n | 127.0.0.1:5678 | https://n8n.marin.cr | `docs/n8n-setup.md` |
| Authentik | 127.0.0.1:9000 | https://auth.marin.cr | `docs/authentik-setup.md` |
| Knecta Web | 127.0.0.1:3101 | https://knecta.marin.cr | `docs/knecta-setup.md` |
| Knecta API | 127.0.0.1:3100 | https://knecta.marin.cr/api | `docs/knecta-setup.md` |

All applications (except PostgreSQL) bind to localhost only and are accessed through the Nginx reverse proxy with TLS.

---

## Strategy

## Operator & Automation Preferences (Important)

This section documents **explicit operator preferences**. These are intentional and should be respected by humans **and by any AI agents** operating on this repository or server.

### Editing & Interaction Preferences

* **Editor:** `nano`

  * All instructions, scripts, and runbooks should assume `nano` as the editor.
  * Do **not** suggest `vim`, `vi`, or other editors unless explicitly requested.

* **Command style:**

  * Prefer **explicit, readable commands** over shortcuts or abstractions.
  * Avoid shell tricks, aliases, or advanced Bash features unless clearly justified.

* **Step-by-step execution:**

  * Changes should be broken into **small, verifiable steps**.
  * After each step, include a simple verification command where applicable.

### Git & Version Control Preferences

* **Git-first mindset:**

  * Infrastructure changes should be committed at clear milestones.
  * Commits should be small, descriptive, and represent stable checkpoints.

* **No secrets in Git (non-negotiable):**

  * Never commit credentials, tokens, certificates, or private keys.
  * Use `.env` files and ignored directories for secrets and runtime data.

* **Main branch workflow:**

  * The `main` branch represents the deployed state of the server.
  * Avoid experimental or partially working commits on `main`.

### Operating Model

* **Root user is intentional:**

  * This server is operated directly as `root`.
  * Instructions should not assume `sudo` or non-root users unless explicitly stated.

* **Clarity over cleverness:**

  * Prefer explicit configuration over dynamic variables or templating.
  * Avoid indirection (e.g., shell variables) unless it improves clarity.

* **Deterministic behavior:**

  * Commands should produce predictable results.
  * Avoid automation that obscures state or makes debugging harder.

### AI Agent Guidance

When this repository or documentation is used as input to AI agents:

* Assume the operator values **control, transparency, and understanding** over speed.
* Do not introduce tools, frameworks, or patterns that were not explicitly requested.
* Favor explanations alongside actions.
* Treat this document as the **source of truth** for how changes should be proposed and applied.

---

### 1) “One app = one folder = one Compose file”

Each app will live under `/opt/infra/apps/<appname>` with:

* `compose.yml` — the Docker Compose definition
* `.env` — runtime secrets (NOT committed)
* `data/` — persistent data (NOT committed)

This enables independent deployment and upgrades:

* `docker compose pull`
* `docker compose up -d`

### 2) One shared reverse proxy

A single Nginx stack under `/opt/infra/proxy` listens on ports 80/443 and routes by hostname.

* Per-host configs go in `proxy/nginx/conf.d/*.conf` and are committed to Git.
* Certificates and ACME challenge files live on disk but are excluded from Git.

### 3) Infrastructure as Code (without secrets)

Everything needed to rebuild the platform is versioned in Git **except**:

* secrets (`.env`)
* persistent volumes (`data/`)
* certs (`proxy/letsencrypt/`)
* ACME webroot (`proxy/webroot/`)
* backups (`backups/`)

---

## Folder structure

Root folder:

```
/opt/infra
  apps/          # Application stacks (each app has its own folder)
    marinapp/    # Custom full-stack application
    nextcloud/   # File synchronization service
    n8n/         # Workflow automation platform
    postgres/    # PostgreSQL + pgAdmin
  proxy/         # Reverse proxy stack (Nginx) + TLS assets
  shared/        # Shared scripts, backups, utilities
  docs/          # Documentation/runbooks (this file lives here)
```

Proxy subtree:

```
/opt/infra/proxy
  compose.yml
  nginx/
    conf.d/      # Virtual hosts (per hostname)
    snippets/    # Reusable config snippets (optional)
  letsencrypt/   # TLS certs (created later; not committed)
  webroot/       # ACME challenge files (created later; not committed)
```

Git ignore policy (current intent):

* `**/.env`
* `**/data/`
* `**/secrets/`
* `**/backups/`
* `proxy/letsencrypt/`
* `proxy/webroot/`

---

## What has been configured so far

### Phase 0 — Baseline OS

* Updated Ubuntu packages
* Hardened SSH for root usage (key-based auth expected)

### Phase 0 — Firewall (UFW)

UFW is enabled with a default-deny incoming policy, allowing only required ports.

Current rule posture:

* Default: deny incoming, allow outgoing
* Allowed inbound: 22, 80, 443, 5432 (and IPv6 equivalents)

### Phase 3 — TLS & Certificate Management (Completed)

* Let's Encrypt certificates issued for all domains via certbot (webroot method)
* HTTPS server blocks configured in Nginx per hostname
* Centralized certificate renewal via `/opt/infra/shared/renew-all-certs.sh`
* Auto-renewal configured via cron

### Phase 4 — Applications (Completed)

* **PostgreSQL + pgAdmin** — Database server with web admin interface
* **Cockpit** — System administration UI with HTTP Basic Auth
* **Nextcloud** — File synchronization with S3 backend and Redis cache
* **MarinApp** — Custom full-stack application (Vite frontend + API)
* **n8n** — Workflow automation platform using PostgreSQL backend

---

## Step-by-step instructions performed

> All commands below were executed as **root**.

### 1) Create the infra directory skeleton

```bash
mkdir -p /opt/infra/{apps,proxy,shared,docs}
```

**What it does:** establishes a stable root directory for all infrastructure configuration and services.

---

### 2) Initialize Git repo and baseline commit

```bash
cd /opt/infra
git init
```

Created `.gitignore` (edited with `nano`):

```gitignore
**/.env
**/data/
**/secrets/
**/backups/
proxy/letsencrypt/
proxy/webroot/
```

Committed baseline:

```bash
git add .
git commit -m "Initial infra directory structure"
```

Configured Git identity and editor:

```bash
git branch -m main
git config --global user.name "Oscar Marin"
git config --global user.email "oscar@marin.cr"
git config --global core.editor "nano"
```

---

### 3) Enable UFW and allow required ports

```bash
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 5432/tcp

ufw enable
ufw status verbose
```

**What it does:** blocks unsolicited inbound traffic except for explicitly allowed ports.

---

### 4) Install Docker Engine + Docker Compose plugin (official repo)

Installed prerequisites:

```bash
apt update
apt install -y ca-certificates curl gnupg
```

Added Docker’s official apt signing key:

```bash
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
```

Added Docker’s official repository:

```bash
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" \
> /etc/apt/sources.list.d/docker.list
```

Installed Docker and Compose:

```bash
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Enabled and started Docker:

```bash
systemctl enable --now docker
```

Verified:

```bash
docker version
docker compose version
```

---

### 5) Create shared Docker network for proxy routing

A dedicated Docker network named `proxy` is used as a shared internal network between the reverse proxy and all application containers.

**Why this matters:**

* Allows Nginx to route to containers by service name (DNS-based) instead of hardcoded IPs
* Prevents applications from needing public port mappings
* Enables clean separation between public ingress (Nginx) and internal services

Checked networks and created the shared `proxy` network:

```bash
docker network ls
docker network create proxy
docker network ls
```

**What it does:** provides a shared internal network so Nginx can route to app containers by name.

---

### 6) Configure Nginx reverse proxy (HTTP-only baseline)

At this stage, Nginx is intentionally configured in **HTTP-only mode** with a simple placeholder response.

**Purpose of this baseline:**

* Verify DNS, firewall, and container networking are correct
* Establish the reverse proxy pattern early
* Prepare the filesystem layout required for future Let’s Encrypt (ACME) challenges

No applications are proxied yet; HTTPS and `proxy_pass` directives will be added in later phases.

Created proxy directory structure:

```bash
mkdir -p /opt/infra/proxy/{nginx/conf.d,nginx/snippets,letsencrypt,webroot}
```

Created `/opt/infra/proxy/compose.yml`:

```yaml
services:
  nginx:
    image: nginx:1.27-alpine
    container_name: proxy-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./nginx/snippets:/etc/nginx/snippets:ro
      - ./letsencrypt:/etc/letsencrypt
      - ./webroot:/var/www/certbot
    networks:
      - proxy

networks:
  proxy:
    external: true
```

Started Nginx:

```bash
cd /opt/infra/proxy
docker compose up -d
```

Created a default HTTP server config (placeholder + future ACME support):

File: `/opt/infra/proxy/nginx/conf.d/00-default-http.conf`

```nginx
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 200 "OK: nginx is running (HTTP)\n";
        add_header Content-Type text/plain;
    }
}
```

Reloaded Nginx safely:

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

Verified HTTP routing (example hostname):

```bash
curl http://pgadmin.marin.cr
```

Expected response:

```
OK: nginx is running (HTTP)
```

---

### 7) Push infra repo to GitHub

Generated a GitHub SSH key for the VPS:

```bash
ssh-keygen -t ed25519 -C "oscar@marin.cr (infra vps)"
```

Added the public key to GitHub (Settings → SSH and GPG keys), then verified:

```bash
ssh -T git@github.com
```

Added remote and pushed:

```bash
cd /opt/infra
git remote add origin git@github.com:marinoscar/marin-server-infra.git
git push -u origin main
```

Verified tracking:

```bash
git remote -v
git status
```

---

## Current operational commands

### Proxy lifecycle

The reverse proxy is operated and debugged entirely via Docker. Logs, reloads, and validation are all performed against the running container.

Common commands:

```bash
cd /opt/infra/proxy
docker compose up -d

docker logs -f proxy-nginx

docker exec proxy-nginx nginx -t

docker exec proxy-nginx nginx -s reload
```

### Network checks

```bash
ss -tulnp | egrep ':80|:443'
ufw status verbose
```

---

## Next steps (planned)

### Phase 5 — Hardening (Optional)

* Enable TLS on PostgreSQL
* Force SSL-only via `pg_hba.conf` (`hostnossl reject`, `hostssl ... scram-sha-256`)
* Consider IP allowlisting for PostgreSQL if possible
* Add IP allowlisting at Nginx level for admin interfaces (Cockpit, pgAdmin, n8n)

### Adding new applications

To add a new application, follow the established pattern:

1. Create folder under `/opt/infra/apps/<appname>`
2. Create `compose.yml` with localhost-only port binding
3. Create `.env` for secrets (never commit)
4. Add Nginx config in `proxy/nginx/conf.d/<domain>.conf`
5. Issue TLS certificate with certbot
6. Document setup in `docs/<appname>-setup.md`

---

## Notes and cautions

* Keeping infra config in Git is a best practice, **but never commit secrets**.
* Public PostgreSQL (5432) should be hardened or IP-restricted as soon as practical.
* If you later enable HTTPS, port 80 must remain open for HTTP-01 certificate renewal (unless you switch to DNS-01 challenges).

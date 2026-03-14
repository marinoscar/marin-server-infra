# Knecta — Server Setup & Deployment

This document describes how to install and run **Knecta** (ontology-based data intelligence platform) on the Ubuntu VPS using the existing `/opt/infra` infrastructure model.

It follows the same conventions as the rest of this repository:

* Root-operated server
* Docker Compose per app
* Nginx reverse proxy (Docker)
* No secrets committed to Git
* Deterministic, repeatable steps

This file is intended to be a **knowledge base / runbook** you can reuse or hand to an AI agent without additional context.

---

## 1. Prerequisites

Before installing Knecta, the following must already be in place:

* Ubuntu VPS with `/opt/infra` initialized
* Docker + Docker Compose installed
* Shared Docker network `proxy` created
* Nginx reverse proxy running from `/opt/infra/proxy`
* PostgreSQL running and accessible at `pgadmin.marin.cr:5432`
* Valid DNS record:
  * `knecta.marin.cr` → VPS IP
* SSL certificate will be issued as part of this setup
* Git access to `github.com/marinoscar/Knecta`

If any of the above is missing, complete the base server and proxy setup first.

---

## 2. What is Knecta

Knecta (pronounced "connect-a") is an open platform that connects databases and turns them into an askable knowledge layer. Users ask questions in plain English and get trusted answers backed by traceable SQL and full data lineage.

### Architecture

Knecta uses a multi-container stack:

| Component | Technology | Purpose |
|-----------|-----------|---------|
| **Web** | React, TypeScript, Material UI | Frontend (static files via nginx:alpine) |
| **API** | NestJS, Fastify, TypeScript | Backend REST API + SSE streaming |
| **Neo4j** | Neo4j 5 Community | Graph database for ontology storage |
| **Sandbox** | Python (Flask/Gunicorn) | Isolated code execution for data verification |

### Key Features

* Multi-database support (PostgreSQL, MySQL, SQL Server, Databricks, Snowflake)
* AI-powered semantic modeling with graph ontology (Neo4j)
* Natural language querying with a six-phase AI agent pipeline
* Mandatory verification phase catches errors before they reach users
* SSE streaming for real-time progress updates
* Google OAuth authentication with role-based access control
* AES-256-GCM encryption for stored database credentials

---

## 3. Directory Layout

Knecta lives under:

```
/opt/infra/apps/knecta
```

After installation, the structure looks like:

```
/opt/infra/apps/knecta
├── .env                    # Environment file (NOT committed)
├── .env.example            # Configuration template
├── compose.yml             # Docker Compose file
├── knecta.conf             # Nginx proxy config (copied to proxy/nginx/conf.d/)
├── install-knecta.sh       # Initial installation script
├── update.sh               # Update/upgrade script
├── rollback.sh             # Rollback script with migration support
├── DEPLOY.md               # Comprehensive deployment runbook
├── .update-state           # Update tracking metadata (written by update.sh)
├── repo/                   # Cloned source code (NOT committed)
└── data/
    └── neo4j/              # Persistent Neo4j graph database (NOT committed)
```

Key points:

* **`.env` contains all configuration** including database credentials, API keys, and OAuth secrets
* **`repo/` contains the cloned source** from `github.com/marinoscar/Knecta`
* **`data/neo4j/` stores the graph database** persistently
* **`knecta.conf` is the proxy config** — `update.sh` copies it to the proxy directory when it changes

---

## 4. Create the PostgreSQL Database

Knecta requires a PostgreSQL database on the existing server.

### 4.1 Connect to PostgreSQL

```bash
psql -h pgadmin.marin.cr -U admin -d postgres
```

### 4.2 Create the database

```sql
CREATE DATABASE knecta;
\q
```

### 4.3 Verify the database exists

```sql
\l
```

You should see `knecta` in the list.

---

## 5. Create the Application Folder

```bash
mkdir -p /opt/infra/apps/knecta/data/neo4j
cd /opt/infra/apps/knecta
```

---

## 6. Create the Environment File

```bash
nano /opt/infra/apps/knecta/.env
```

Use `.env.example` as a reference. Key variables include:

```env
# Database (PostgreSQL — existing server)
DATABASE_URL=postgresql://admin:<password>@pgadmin.marin.cr:5432/knecta

# Neo4j
NEO4J_URI=bolt://neo4j:7687
NEO4J_USER=neo4j
NEO4J_PASSWORD=CHANGE_ME

# LLM Providers (at least one required)
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...

# Authentication (Google OAuth)
GOOGLE_CLIENT_ID=...
GOOGLE_CLIENT_SECRET=...
GOOGLE_CALLBACK_URL=https://knecta.marin.cr/api/auth/google/callback

# Encryption
ENCRYPTION_KEY=CHANGE_ME_32_CHAR_HEX

# S3 Storage (for file uploads)
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_S3_BUCKET=...
AWS_REGION=...

# Initial admin user
INITIAL_USER_EMAIL=your-email@example.com
```

**Never commit this file to Git.**

---

## 7. Create the Docker Compose File

The `compose.yml` defines four services:

```yaml
services:
  api:
    # NestJS backend — production build
    ports:
      - "127.0.0.1:3100:3000"
    mem_limit: 512m
    depends_on: [neo4j, sandbox]

  web:
    # React frontend — static files via nginx:alpine
    ports:
      - "127.0.0.1:3101:80"
    mem_limit: 128m

  neo4j:
    # Graph database for ontology
    image: neo4j:5-community
    # Internal only — no public port
    mem_limit: 512m

  sandbox:
    # Python code execution environment
    # Internal only — no public port
    mem_limit: 512m
    cpus: 1.0
```

Key points:

* API and Web bind to `127.0.0.1` only (localhost, not public)
* Neo4j and Sandbox are internal-only (no port mappings)
* All services use a single `app-network` bridge network
* Health checks configured for all services
* Memory limits enforced per container

---

## 8. Installation

Use the provided installation script:

```bash
cd /opt/infra/apps/knecta
./install-knecta.sh
```

The script performs these steps:

1. Creates data directories
2. Clones the Knecta repository from `origin/main`
3. Validates `.env` exists
4. Builds Docker images and starts Neo4j + Sandbox first
5. Runs Prisma database migrations and seed
6. Starts all services
7. Verifies health

---

## 9. Configure Nginx Reverse Proxy

### 9.1 Copy the proxy configuration

The Knecta repo includes a proxy config that gets copied to the proxy directory:

```bash
cp /opt/infra/apps/knecta/knecta.conf /opt/infra/proxy/nginx/conf.d/knecta.conf
```

### 9.2 Proxy routing

The Nginx config routes traffic for `knecta.marin.cr`:

| Path Pattern | Destination | Notes |
|-------------|-------------|-------|
| `/api/semantic-models/runs/.../stream` | `127.0.0.1:3100` | SSE streaming (buffering off, 300s timeout) |
| `/api/data-agent/chats/.../messages/.../stream` | `127.0.0.1:3100` | SSE streaming (buffering off, 300s timeout) |
| `/api/*` | `127.0.0.1:3100` | API routes (WebSocket upgrade support) |
| `/*` | `127.0.0.1:3101` | React frontend static files |

Additional configuration:

* HSTS enabled with 2-year max-age
* Security headers: X-Frame-Options, X-Content-Type-Options, X-XSS-Protection
* Client upload limit: 110MB
* SSE endpoints have buffering disabled for real-time streaming

### 9.3 Test and reload Nginx

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

---

## 10. Issue TLS Certificate

### 10.1 Issue the certificate

```bash
docker run --rm \
  -v /opt/infra/proxy/letsencrypt:/etc/letsencrypt \
  -v /opt/infra/proxy/webroot:/var/www/certbot \
  certbot/certbot:latest certonly \
  --webroot -w /var/www/certbot \
  -d knecta.marin.cr \
  --email oscar@marin.cr \
  --agree-tos \
  --no-eff-email
```

### 10.2 Verify certificate was issued

```bash
ls -la /opt/infra/proxy/letsencrypt/live/knecta.marin.cr/
```

---

## 11. Verify Deployment

```bash
curl -I https://knecta.marin.cr/
curl -I https://knecta.marin.cr/api/health
```

Expected: `200 OK` for both.

---

## 12. Certificate Renewal

The existing `/opt/infra/shared/renew-all-certs.sh` automatically handles certificate renewal for `knecta.marin.cr`.

---

## 13. Operational Commands

### Start/stop Knecta

```bash
cd /opt/infra/apps/knecta
docker compose up -d
docker compose down
```

### View logs

```bash
docker compose logs --tail 100 api
docker compose logs --tail 100 web
docker compose logs -f api
```

### Restart Knecta

```bash
cd /opt/infra/apps/knecta
docker compose restart
```

### Update to latest version

```bash
cd /opt/infra/apps/knecta
./update.sh
```

The update script:
1. Pulls latest code from `origin/main`
2. Rebuilds Docker images (only if code changed)
3. Runs database migrations
4. Restarts services
5. Updates proxy config if changed
6. Verifies health
7. Saves rollback state to `.update-state`

Supports flags: `--no-cache` (force rebuild), `--skip-proxy` (skip proxy update).

### Rollback to previous version

```bash
cd /opt/infra/apps/knecta
./rollback.sh               # rollback to previous version (from .update-state)
./rollback.sh <commit>      # rollback to specific commit
```

The rollback script handles database migration reversal automatically using Prisma.

### Backup

Database backup (PostgreSQL):

```bash
pg_dump -h pgadmin.marin.cr -U admin knecta > /opt/infra/apps/knecta/knecta-backup-$(date +%Y%m%d).sql
```

---

## 14. Troubleshooting

### A) API won't start: database connection error

**Cause:** PostgreSQL not reachable or wrong credentials.

**Fix:**

1. Verify PostgreSQL is running: `psql -h pgadmin.marin.cr -U admin -d knecta -c "\conninfo"`
2. Check `DATABASE_URL` in `.env`
3. Check logs: `docker compose logs api`

### B) Neo4j won't start

**Cause:** Data directory permissions or disk space.

**Fix:**

```bash
ls -la /opt/infra/apps/knecta/data/neo4j/
docker compose logs neo4j
```

### C) SSE streaming not working

**Cause:** Nginx buffering or timeout misconfiguration.

**Fix:** Verify the SSE location blocks in `knecta.conf` have `proxy_buffering off` and adequate timeouts (300s).

### D) OAuth callback fails

**Cause:** `GOOGLE_CALLBACK_URL` doesn't match the URL configured in Google Cloud Console.

**Fix:** Ensure `GOOGLE_CALLBACK_URL=https://knecta.marin.cr/api/auth/google/callback` in `.env` and matches Google OAuth settings.

---

## 15. Security Considerations

* **Database credentials encrypted:** All stored connection credentials use AES-256-GCM encryption
* **Google OAuth:** Authentication is handled externally via Google
* **HSTS enabled:** Browser enforcement of HTTPS with 2-year duration
* **Security headers:** X-Frame-Options, X-Content-Type-Options, X-XSS-Protection configured
* **Memory limits:** All containers have enforced memory limits to prevent resource exhaustion
* **Sandbox isolation:** Python code execution runs in a separate container with CPU limits

---

## Current Final State (Known-Good)

* Knecta API: internal on `127.0.0.1:3100` (not public)
* Knecta Web: internal on `127.0.0.1:3101` (not public)
* Neo4j: internal only (no public port)
* Sandbox: internal only (no public port)
* Nginx: routes `https://knecta.marin.cr` → API and Web containers
* Database: PostgreSQL `knecta` database on existing instance at `pgadmin.marin.cr`
* TLS: Let's Encrypt cert at `/opt/infra/proxy/letsencrypt/live/knecta.marin.cr/`

---

## Sources

* [Knecta Repository](https://github.com/marinoscar/Knecta)
* [Knecta DEPLOY.md](/opt/infra/apps/knecta/DEPLOY.md)

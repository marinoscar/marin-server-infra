# Knecta - VPS Deployment Runbook

This document describes how to deploy **Knecta** on an Ubuntu VPS using the `/opt/infra` infrastructure model.

It follows the same conventions as the rest of the infrastructure repository:

* Root-operated server
* Docker Compose per app
* Shared Nginx reverse proxy (Docker)
* No secrets committed to Git
* Deterministic, repeatable steps

---

## 1. Prerequisites

Before deploying Knecta, the following must already be in place:

* Ubuntu VPS with `/opt/infra` initialized
* Docker + Docker Compose installed
* Shared Docker network `proxy` created (`docker network create proxy`)
* Nginx reverse proxy running from `/opt/infra/proxy`
* DNS A record: `knecta.marin.cr` pointing to VPS IP
* **Cloud-hosted PostgreSQL** instance accessible from the VPS
* Google OAuth credentials configured for `knecta.marin.cr`
* S3 bucket (AWS, R2, or MinIO) for file storage
* At least one LLM API key (OpenAI or Anthropic)

---

## 2. Architecture

```
Internet
   |
   v
VPS Nginx Proxy (knecta.marin.cr:443)
   |  proxy Docker network
   |
   +---> knecta-api (:3000)    <-- NestJS API (node:20-alpine)
   |        |  app-network
   |        +---> knecta-neo4j (:7687)   <-- Neo4j 5 (graph DB)
   |        +---> knecta-sandbox (:8000) <-- Python code runner
   |
   +---> knecta-web (:80)      <-- React static files (nginx:alpine)
   |
   +- - -> Cloud PostgreSQL     <-- External (not in Docker)
```

Key points:

* Single domain `knecta.marin.cr` handles both frontend and API
* The VPS Nginx proxy routes `/api` to `knecta-api:3000` and `/` to `knecta-web:80`
* PostgreSQL is external (cloud-hosted), not a Docker container
* Neo4j and the Python sandbox run as Docker containers on the internal network
* The API and Web containers are on both `app-network` (internal) and `proxy` (VPS proxy)

---

## 3. Directory Layout

After deployment, the structure on the VPS:

```
/opt/infra/apps/knecta/
    .env                    # Runtime secrets (NOT committed)
    .env.example            # Template for reference
    compose.yml             # Docker Compose file
    knecta.conf             # VPS proxy config (copy to proxy/nginx/conf.d/)
    install-knecta.sh       # Installer script
    repo/                   # Cloned application source code
    data/                   # Persistent data (NOT committed)
        neo4j/              # Neo4j graph data
```

---

## 4. Initial Deployment

### Step 1: Create the app directory

```bash
mkdir -p /opt/infra/apps/knecta
cd /opt/infra/apps/knecta
```

### Step 2: Copy deployment files

Copy the contents of `infra/deploy/` from the Knecta repo to `/opt/infra/apps/knecta/`:

```bash
# Option A: Clone the repo first, then copy
git clone https://github.com/marinoscar/Knecta.git /tmp/knecta-deploy
cp /tmp/knecta-deploy/infra/deploy/* /opt/infra/apps/knecta/
rm -rf /tmp/knecta-deploy

# Option B: If you already have the files locally, scp them
# scp -r infra/deploy/* root@your-vps:/opt/infra/apps/knecta/
```

Make the install script executable:

```bash
chmod +x /opt/infra/apps/knecta/install-knecta.sh
```

### Step 3: Configure environment

```bash
cd /opt/infra/apps/knecta
cp .env.example .env
nano .env
```

**Required values to change** (marked `CHANGE_ME` in the template):

| Variable | How to generate / where to find |
|----------|-------------------------------|
| `POSTGRES_HOST` | Your cloud PostgreSQL hostname |
| `POSTGRES_USER` | Cloud PostgreSQL username |
| `POSTGRES_PASSWORD` | Cloud PostgreSQL password |
| `NEO4J_PASSWORD` | `openssl rand -base64 24` (min 8 chars) |
| `JWT_SECRET` | `openssl rand -base64 32` |
| `COOKIE_SECRET` | `openssl rand -base64 32` |
| `ENCRYPTION_KEY` | `openssl rand -base64 32` |
| `GOOGLE_CLIENT_ID` | [Google Cloud Console](https://console.cloud.google.com/apis/credentials) |
| `GOOGLE_CLIENT_SECRET` | Same as above |
| `INITIAL_ADMIN_EMAIL` | Your email for first admin login |
| `S3_BUCKET` | Your S3 bucket name |
| `AWS_ACCESS_KEY_ID` | AWS IAM credentials |
| `AWS_SECRET_ACCESS_KEY` | AWS IAM credentials |
| `OPENAI_API_KEY` | [OpenAI Dashboard](https://platform.openai.com/api-keys) |

### Step 4: Run the install script

```bash
cd /opt/infra/apps/knecta
./install-knecta.sh
```

This will:
1. Clone the repository to `./repo/`
2. Build Docker images (api, web, sandbox) and pull neo4j
3. Start all 4 containers
4. Run Prisma migrations against your cloud PostgreSQL (creates all tables)
5. Run database seed (creates roles, permissions, system settings)
6. Verify service health

Expected build time: 3-5 minutes on first run.

### Step 5: Configure VPS reverse proxy

Copy the proxy config:

```bash
cp /opt/infra/apps/knecta/knecta.conf /opt/infra/proxy/nginx/conf.d/
```

### Step 6: Obtain TLS certificate

Using the webroot method (proxy stays running):

```bash
certbot certonly --webroot -w /opt/infra/proxy/webroot -d knecta.marin.cr
```

Or standalone method (temporarily stops proxy):

```bash
cd /opt/infra/proxy
docker compose stop
certbot certonly --standalone -d knecta.marin.cr
docker compose up -d
```

### Step 7: Reload VPS proxy

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

### Step 8: Configure Google OAuth

In [Google Cloud Console](https://console.cloud.google.com/apis/credentials), add the authorized redirect URI:

```
https://knecta.marin.cr/api/auth/google/callback
```

### Step 9: Verify

```bash
# Check all containers
docker compose -f /opt/infra/apps/knecta/compose.yml ps

# API health (includes database connectivity check)
curl https://knecta.marin.cr/api/health/ready

# Web frontend
curl -sI https://knecta.marin.cr/ | head -5
```

Open `https://knecta.marin.cr` in a browser and log in via Google OAuth.

---

## 5. Updating Knecta

To deploy the latest code:

```bash
cd /opt/infra/apps/knecta
./install-knecta.sh
```

The script detects the existing repository and runs `git pull` instead of `git clone`. It rebuilds images, runs any new migrations against the cloud database, and restarts all services.

---

## 6. Backup

### Neo4j

Neo4j Community Edition does not support online backup. Stop the container first:

```bash
cd /opt/infra/apps/knecta
docker compose stop neo4j
cp -r data/neo4j /opt/infra/backups/knecta-neo4j-$(date +%Y%m%d)
docker compose start neo4j
```

### PostgreSQL

PostgreSQL is cloud-hosted. Use your cloud provider's backup tools (automated snapshots, pg_dump from the provider's dashboard, etc.).

---

## 7. Operational Commands

### View logs

```bash
cd /opt/infra/apps/knecta

# All services
docker compose logs -f

# Specific service
docker compose logs -f api
docker compose logs -f web
docker compose logs -f neo4j
docker compose logs -f sandbox
```

### Restart services

```bash
cd /opt/infra/apps/knecta
docker compose restart           # All services
docker compose restart api       # Just the API
```

### Full rebuild (after code changes)

```bash
cd /opt/infra/apps/knecta
docker compose build --no-cache
docker compose up -d
```

### Run Prisma migrations manually

```bash
docker compose -f /opt/infra/apps/knecta/compose.yml exec api npm run prisma:migrate
```

---

## 8. Troubleshooting

### API won't start

```bash
docker compose logs api
```

Common causes:
* Cloud PostgreSQL not reachable (check `POSTGRES_HOST`, firewall rules, SSL settings)
* Missing environment variable (check `.env` for `CHANGE_ME` values)
* Prisma migrations not run (run `docker compose exec api npm run prisma:migrate`)

### Cannot connect to cloud PostgreSQL

* Verify `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_PASSWORD` in `.env`
* Ensure `POSTGRES_SSL=true` if your cloud provider requires SSL
* Check that the VPS IP is allowlisted in your cloud PostgreSQL firewall/security group
* Test connectivity: `docker compose exec api node -e "const net=require('net');const s=net.connect(5432,'YOUR_HOST',()=>{console.log('OK');s.end()})"`

### Neo4j authentication failure

Neo4j requires passwords of at least 8 characters. Check `NEO4J_PASSWORD` in `.env`.

### SSE streaming not working (agent timeouts)

Verify that the VPS proxy config (`knecta.conf`) has:
* Dedicated SSE location blocks for `/api/semantic-models/runs/.../stream` and `/api/data-agent/chats/.../messages/.../stream`
* `proxy_buffering off` on those locations
* 300s timeouts

### OAuth redirect mismatch

Ensure `GOOGLE_CALLBACK_URL` in `.env` matches exactly what is registered in Google Cloud Console:
```
https://knecta.marin.cr/api/auth/google/callback
```

### Container name conflicts

If containers from a previous install exist:

```bash
cd /opt/infra/apps/knecta
docker compose down
docker compose up -d --build
```

---

## 9. Design Notes

* Source code lives in `repo/` and is fully replaceable via `git pull`
* Configuration is centralized in `.env` (single source of truth)
* Docker images are rebuilt explicitly (no auto-pull)
* The VPS Nginx proxy handles TLS termination and routes directly to API/Web containers
* No internal Nginx — the VPS proxy does all routing (`/api` → api, `/` → web)
* PostgreSQL is external (cloud-hosted) — not managed by Docker
* Neo4j data persists in `data/neo4j/` bind mount (easy to back up)

---

## 10. Certificate Renewal

Certbot auto-renewal should already be configured on the VPS. Verify:

```bash
certbot renew --dry-run
```

If Knecta's certificate was added after the initial certbot setup, it will be included automatically in the next renewal cycle.

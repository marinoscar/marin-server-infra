# Sink — Production Deployment Runbook

This document describes how to deploy and maintain the Sink application on the VPS.

## Overview

- **Public URL**: https://sink.dev.marin.cr
- **VPS app path**: /opt/infra/apps/sink/
- **Repository**: https://github.com/marinoscar/sink.git
- **Internal port**: 127.0.0.1:8321 (Sink Nginx container, reached by the VPS proxy)

## Architecture

```
Internet (HTTPS)
  |
  v
VPS Nginx Proxy (proxy-nginx, ports 80/443)
  |
  v  sink.dev.marin.cr -> 127.0.0.1:8321
Sink Nginx (sink-nginx, port 8321)
  |-- /api              -> sink-api:3000  (NestJS + Fastify)
  +-- /                 -> sink-web:80    (React static build)

sink-api -> PostgreSQL (via POSTGRES_HOST, supports SSL)
         -> AWS S3 (file storage)
```

The VPS proxy handles TLS termination using the wildcard certificate for `*.dev.marin.cr`. Traffic for `sink.dev.marin.cr` is forwarded to the Sink Nginx container, which routes between the API and the static web frontend.

---

## Prerequisites

Before starting the deployment, confirm the following are in place:

1. **Ubuntu VPS** with Docker and Docker Compose installed
2. **VPS reverse proxy** running at `/opt/infra/proxy/` (the `proxy-nginx` container)
3. **DNS** — wildcard A record `*.dev.marin.cr` already pointing to the VPS IP
4. **Wildcard TLS certificate** for `*.dev.marin.cr` already provisioned at `/etc/letsencrypt/live/dev.marin.cr/` (no new cert needed)
5. **PostgreSQL instance** accessible from the VPS (e.g., pgadmin.marin.cr or a cloud provider) with connection credentials ready
6. **Google OAuth credentials** with the redirect URI configured:
   `https://sink.dev.marin.cr/api/auth/google/callback`
7. **AWS S3 bucket** created with IAM credentials that have read/write access

---

## First-Time Installation

### Step 1 — Create the application directory

```bash
mkdir -p /opt/infra/apps/sink
cd /opt/infra/apps/sink
```

### Step 2 — Create the .env file

Create `/opt/infra/apps/sink/.env` with production values. Do not copy this file from the repository — it contains secrets and must never be committed to version control.

```bash
nano /opt/infra/apps/sink/.env
```

Use the following template, replacing all placeholder values:

```bash
# =============================================================================
# Sink — Production Environment
# =============================================================================

# Application
COMPOSE_PROJECT_NAME=sink
NODE_ENV=production
PORT=3000
APP_URL=https://sink.dev.marin.cr

# Database (PostgreSQL)
# DATABASE_URL is constructed automatically from these values at runtime.
# URL-encode the password if it contains special characters.
POSTGRES_HOST=pgadmin.marin.cr
POSTGRES_PORT=5432
POSTGRES_USER=admin
POSTGRES_PASSWORD=your-postgres-password
POSTGRES_DB=sink
POSTGRES_SSL=true

# JWT / Session
# Generate with: openssl rand -hex 32
JWT_SECRET=your-jwt-secret-min-32-chars
JWT_ACCESS_TTL_MINUTES=15
JWT_REFRESH_TTL_DAYS=14
COOKIE_SECRET=your-cookie-secret-min-32-chars

# OAuth - Google (Required)
# Redirect URI must be: https://sink.dev.marin.cr/api/auth/google/callback
GOOGLE_CLIENT_ID=your-google-client-id
GOOGLE_CLIENT_SECRET=your-google-client-secret
GOOGLE_CALLBACK_URL=https://sink.dev.marin.cr/api/auth/google/callback

# Initial Admin Bootstrap
# First user to log in with this email is assigned the Admin role
INITIAL_ADMIN_EMAIL=admin@example.com

# Device Authorization Flow (RFC 8628)
DEVICE_CODE_EXPIRY_MINUTES=15
DEVICE_CODE_POLL_INTERVAL=5

# Storage - AWS S3
STORAGE_PROVIDER=s3
S3_BUCKET=your-s3-bucket-name
S3_REGION=us-east-1
AWS_ACCESS_KEY_ID=your-aws-access-key-id
AWS_SECRET_ACCESS_KEY=your-aws-secret-access-key

# Storage limits
MAX_FILE_SIZE=10737418240
ALLOWED_MIME_TYPES=image/*,application/pdf,video/*
SIGNED_URL_EXPIRY=3600
STORAGE_PART_SIZE=10485760

# Calendar Sync
# Generate with: openssl rand -hex 32
CALENDAR_ENCRYPTION_KEY=your-calendar-encryption-key

# Observability
OTEL_ENABLED=false
LOG_LEVEL=info
```

Generate secrets with:

```bash
openssl rand -hex 32   # JWT_SECRET
openssl rand -hex 32   # COOKIE_SECRET
openssl rand -hex 32   # CALENDAR_ENCRYPTION_KEY
```

### Step 3 — Run the install script

Copy the install script from the repository and run it. The script clones the repository, validates the `.env` file, generates the production `compose.yml` and the VPS proxy config (`sink.conf`), builds the Docker images, runs Prisma migrations, runs seeds, and starts all services.

```bash
# Fetch the script directly from the repository
curl -fsSL https://raw.githubusercontent.com/marinoscar/sink/main/infra/deploy/install-sink.sh \
  -o /opt/infra/apps/sink/install-sink.sh

chmod +x /opt/infra/apps/sink/install-sink.sh
cd /opt/infra/apps/sink
./install-sink.sh
```

The script runs in 7 steps and prints progress for each. If it exits with an error, the output will indicate which step failed and what to check.

### Step 4 — Install the VPS proxy config

The install script generates `sink.conf` at `/opt/infra/apps/sink/sink.conf`. Copy it into the VPS proxy's config directory:

```bash
cp /opt/infra/apps/sink/sink.conf /opt/infra/proxy/nginx/conf.d/sink.conf
```

### Step 5 — Validate and reload the VPS proxy

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

If `nginx -t` reports a syntax error, review the contents of `sink.conf` before reloading.

### Step 6 — Verify

```bash
curl https://sink.dev.marin.cr/api/health/live
```

Expected response: `{"status":"ok"}` or similar. A 200 response confirms TLS, the VPS proxy, the Sink Nginx router, and the API container are all working.

---

## Updating the Application

Copy the update script from the repository (first time only) and run it on subsequent deploys:

```bash
# Fetch once
curl -fsSL https://raw.githubusercontent.com/marinoscar/sink/main/infra/deploy/update.sh \
  -o /opt/infra/apps/sink/update.sh
chmod +x /opt/infra/apps/sink/update.sh

# Run update
cd /opt/infra/apps/sink
./update.sh
```

The update script:
1. Pulls the latest code from `origin/main`
2. Rebuilds Docker images
3. Runs Prisma migrations against the live database
4. Restarts all services
5. Optionally updates the VPS proxy config if `sink.conf` has changed
6. Verifies service health

### Update script options

| Flag | Effect |
|---|---|
| `--no-cache` | Force full Docker rebuild, ignoring layer cache |
| `--skip-proxy` | Skip copying `sink.conf` and reloading the VPS proxy |

```bash
./update.sh --no-cache         # full image rebuild
./update.sh --skip-proxy       # skip proxy reload
./update.sh --no-cache --skip-proxy
```

### Update logs

Each run of `update.sh` writes a timestamped log to `/opt/infra/apps/sink/logs/`. The last 10 log files are kept automatically; older ones are deleted.

```bash
ls /opt/infra/apps/sink/logs/
cat /opt/infra/apps/sink/logs/update-20260101-120000.log
```

---

## Database

### Create the database (first time)

If the PostgreSQL instance does not yet have the `sink` database, create it:

```bash
psql -h pgadmin.marin.cr -U admin -d postgres -c "CREATE DATABASE sink;"
```

The install script runs `prisma migrate deploy` and `prisma db seed` automatically after the database exists.

### Run migrations manually

If you need to run migrations outside of the install or update scripts, construct `DATABASE_URL` manually and use a one-off API container:

```bash
cd /opt/infra/apps/sink

# Source env vars
set -a; . .env; set +a

# URL-encode the password if it contains special characters
ENCODED_PW=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${POSTGRES_PASSWORD}', safe=''))")
DATABASE_URL="postgresql://${POSTGRES_USER}:${ENCODED_PW}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=require"

docker compose -f compose.yml run --rm -e DATABASE_URL="${DATABASE_URL}" api \
  sh -c "npx prisma migrate deploy"
```

### Backup

```bash
mkdir -p /opt/infra/backups
pg_dump -h pgadmin.marin.cr -U admin sink \
  > /opt/infra/backups/sink-$(date +%Y%m%d).sql
```

Store backups off-server (e.g., S3 or a local machine) for disaster recovery.

---

## Service Management

All commands reference the generated compose file at `/opt/infra/apps/sink/compose.yml`.

```bash
# View live logs (follow)
docker compose -f /opt/infra/apps/sink/compose.yml logs -f api
docker compose -f /opt/infra/apps/sink/compose.yml logs -f web
docker compose -f /opt/infra/apps/sink/compose.yml logs -f nginx

# Restart all services
docker compose -f /opt/infra/apps/sink/compose.yml restart

# Restart a single service
docker compose -f /opt/infra/apps/sink/compose.yml restart api

# Stop all services
docker compose -f /opt/infra/apps/sink/compose.yml down

# Start all services
docker compose -f /opt/infra/apps/sink/compose.yml up -d

# Check container status
docker compose -f /opt/infra/apps/sink/compose.yml ps
```

---

## Troubleshooting

### API container won't start

Check the API logs for the startup error:

```bash
docker compose -f /opt/infra/apps/sink/compose.yml logs api
```

Common causes:
- Missing or invalid environment variable (check `.env`)
- Database unreachable at startup (see "Database connection refused" below)
- Prisma schema mismatch (run migrations manually)

### 502 Bad Gateway

The VPS proxy is running but cannot reach the Sink Nginx container.

```bash
# Confirm sink containers are running
docker compose -f /opt/infra/apps/sink/compose.yml ps

# Confirm port 8321 is bound on loopback
ss -tlnp | grep 8321

# If containers are stopped, start them
docker compose -f /opt/infra/apps/sink/compose.yml up -d
```

### Database connection refused

The API cannot connect to PostgreSQL.

Checklist:
1. Confirm `POSTGRES_HOST` is correct and reachable from the VPS:
   ```bash
   nc -zv pgadmin.marin.cr 5432
   ```
2. Confirm `POSTGRES_SSL=true` if the PostgreSQL server requires SSL.
3. Confirm the database user and password are correct.
4. Check firewall rules — the VPS IP may need to be whitelisted on the database server.

### Migration errors

If `prisma migrate deploy` fails, a common cause is a password containing special characters that are not URL-encoded in `DATABASE_URL`.

Construct the URL manually with URL encoding:

```bash
# In a shell on the VPS
python3 -c "import urllib.parse; print(urllib.parse.quote('your-password-here', safe=''))"
# Use the output as the password component in DATABASE_URL
DATABASE_URL="postgresql://admin:ENCODED_PASSWORD@pgadmin.marin.cr:5432/sink?sslmode=require"
```

Then run the migration one-off container as shown in the Database section above.

### OAuth callback error

If Google OAuth returns an error after login:

1. Confirm `GOOGLE_CALLBACK_URL` in `.env` matches exactly what is registered in the Google Cloud Console:
   `https://sink.dev.marin.cr/api/auth/google/callback`
2. Confirm `APP_URL=https://sink.dev.marin.cr` in `.env`.
3. Restart the API container after any `.env` change:
   ```bash
   docker compose -f /opt/infra/apps/sink/compose.yml restart api
   ```

### Proxy config not routing correctly

If traffic is not reaching the Sink containers after a proxy config change:

```bash
# Validate nginx config inside proxy container
docker exec proxy-nginx nginx -t

# If valid, reload without downtime
docker exec proxy-nginx nginx -s reload

# Confirm sink.conf is in place
ls /opt/infra/proxy/nginx/conf.d/
```

---

## File Reference

| File | Location on VPS | Description |
|---|---|---|
| `.env` | `/opt/infra/apps/sink/.env` | Production environment variables (secrets, never commit) |
| `compose.yml` | `/opt/infra/apps/sink/compose.yml` | Generated production Docker Compose file |
| `sink.conf` | `/opt/infra/apps/sink/sink.conf` | Generated VPS proxy Nginx config (source) |
| `sink.conf` (active) | `/opt/infra/proxy/nginx/conf.d/sink.conf` | Active VPS proxy config (copy from above) |
| `install-sink.sh` | `/opt/infra/apps/sink/install-sink.sh` | First-time installation script |
| `update.sh` | `/opt/infra/apps/sink/update.sh` | Incremental update script |
| `logs/` | `/opt/infra/apps/sink/logs/` | Update run logs (last 10 kept) |
| `.update-state` | `/opt/infra/apps/sink/.update-state` | Last update timestamp and commit info |
| Repository | `/opt/infra/apps/sink/repo/` | Cloned source code (managed by install/update scripts) |

# ShellKeep — Production Deployment Runbook

## Overview

Deploy ShellKeep on Ubuntu VPS using the `/opt/infra` infrastructure model.

| Item | Value |
|------|-------|
| **Public URL** | `https://shellkeep.marin.cr` |
| **VPS Path** | `/opt/infra/apps/shellkeep/` |
| **Repository** | `https://github.com/marinoscar/shellkeep.git` |
| **Internal Port** | `127.0.0.1:8323` (Nginx container -> VPS proxy) |
| **Database** | Cloud PostgreSQL (e.g. AWS RDS, Neon, Supabase) |
| **File Storage** | AWS S3 |

## Architecture

```
Internet (HTTPS)
  |
  v
VPS Nginx Proxy (proxy-nginx, ports 80/443)
  |
  v  shellkeep.marin.cr -> 127.0.0.1:8323
ShellKeep Nginx (shellkeep-nginx, port 8323)
  |-- /api/terminal/ws  -> shellkeep-api:3000  (WebSocket, long-lived)
  |-- /api              -> shellkeep-api:3000  (NestJS + Fastify)
  +-- /                 -> shellkeep-web:80    (React static build)

shellkeep-api -> Cloud PostgreSQL (over the internet, SSL)
             -> AWS S3 (file storage)
```

## Prerequisites

1. Ubuntu VPS with Docker and Docker Compose installed
2. VPS reverse proxy running (`/opt/infra/proxy/`)
3. DNS A record: `shellkeep.marin.cr` -> VPS IP
4. Cloud PostgreSQL instance (e.g. AWS RDS, Neon, Supabase) with connection credentials
5. Google OAuth credentials ([console.cloud.google.com](https://console.cloud.google.com))
   - Authorized redirect URI: `https://shellkeep.marin.cr/api/auth/google/callback`
6. AWS S3 bucket with CORS configured for `https://shellkeep.marin.cr`

## Step 1: Create Directory Structure

```bash
mkdir -p /opt/infra/apps/shellkeep
```

## Step 2: Create Environment File

```bash
nano /opt/infra/apps/shellkeep/.env
```

Populate with production values:

```env
# Application
COMPOSE_PROJECT_NAME=shellkeep
NODE_ENV=production
PORT=3000
APP_URL=https://shellkeep.marin.cr

# Database (cloud PostgreSQL)
POSTGRES_HOST=<your-cloud-postgres-host>
POSTGRES_PORT=5432
POSTGRES_USER=<your-postgres-user>
POSTGRES_PASSWORD=<your-postgres-password>
POSTGRES_DB=shellkeep
POSTGRES_SSL=true

# JWT Authentication
JWT_SECRET=<generate with: openssl rand -hex 32>
JWT_ACCESS_TTL_MINUTES=15
JWT_REFRESH_TTL_DAYS=14
COOKIE_SECRET=<generate with: openssl rand -hex 32>

# Encryption (AES-256-GCM for SSH credentials)
ENCRYPTION_KEY=<generate with: openssl rand -base64 32>

# Google OAuth
GOOGLE_CLIENT_ID=<your-google-client-id>
GOOGLE_CLIENT_SECRET=<your-google-client-secret>
GOOGLE_CALLBACK_URL=https://shellkeep.marin.cr/api/auth/google/callback

# AWS S3 Storage
S3_BUCKET=<your-s3-bucket-name>
S3_REGION=us-east-1
AWS_ACCESS_KEY_ID=<your-aws-access-key>
AWS_SECRET_ACCESS_KEY=<your-aws-secret-key>

# Admin Bootstrap (first user with this email becomes admin)
INITIAL_ADMIN_EMAIL=<your-admin-email>

# Logging
LOG_LEVEL=info

# Observability (disable if not using OTEL stack)
OTEL_ENABLED=false
```

## Step 3: Run Install Script

```bash
cd /opt/infra/apps/shellkeep
cp repo/infra/deploy/install-shellkeep.sh .
chmod +x install-shellkeep.sh
./install-shellkeep.sh
```

The script will:
1. Clone (or pull) the repository
2. Validate `.env` exists
3. Generate `compose.yml` and `shellkeep.conf`
4. Build Docker images (production targets)
5. Run Prisma migrations against PostgreSQL
6. Run database seeds (roles, permissions, system settings, admin allowlist)
7. Start all services (api, web, nginx)
8. Verify service health

## Step 4: Configure VPS Reverse Proxy

Copy the Nginx config to the VPS proxy:

```bash
cp /opt/infra/apps/shellkeep/shellkeep.conf /opt/infra/proxy/nginx/conf.d/
```

## Step 5: Issue TLS Certificate

The proxy config references TLS certs, so issue the certificate **before** reloading Nginx:

```bash
certbot certonly \
  --webroot \
  -w /opt/infra/proxy/webroot \
  -d shellkeep.marin.cr \
  --config-dir /opt/infra/proxy/letsencrypt
```

Now validate and reload the proxy:

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

## Step 6: Verify Deployment

```bash
# Health check
curl https://shellkeep.marin.cr/api/health/live

# Readiness check (includes database connectivity)
curl https://shellkeep.marin.cr/api/health/ready
```

Open `https://shellkeep.marin.cr` in a browser and sign in with Google.

## Updating

Copy the update script (first time only):

```bash
cp /opt/infra/apps/shellkeep/repo/infra/deploy/update.sh /opt/infra/apps/shellkeep/
chmod +x /opt/infra/apps/shellkeep/update.sh
```

To deploy updates:

```bash
cd /opt/infra/apps/shellkeep
./update.sh
```

Options:
- `--no-cache` — Force full Docker rebuild (ignores layer cache)
- `--skip-proxy` — Skip VPS proxy config update

The script pulls latest code, rebuilds images, runs migrations, and restarts services. Logs are saved to `./logs/` (last 10 kept).

## Database Backup

Since ShellKeep uses an external PostgreSQL server, back up the database directly:

```bash
pg_dump -h <postgres-host> -U postgres -d shellkeep > /opt/infra/backups/shellkeep-$(date +%Y%m%d).sql
```

## Troubleshooting

### API won't start
```bash
docker compose -f /opt/infra/apps/shellkeep/compose.yml logs api
```

### 502 Bad Gateway
Check that the ShellKeep containers are running:
```bash
docker compose -f /opt/infra/apps/shellkeep/compose.yml ps
```

### Database connection refused
Verify PostgreSQL is reachable from the API container:
```bash
docker exec shellkeep-api sh -c 'wget -qO- http://localhost:3000/api/health/ready'
```

Check that `POSTGRES_HOST` in `.env` is the correct cloud PostgreSQL hostname and that `POSTGRES_SSL=true` is set. Ensure the cloud provider's firewall allows connections from the VPS IP address.

### Migration errors
Stop the API before running migrations manually. You must construct `DATABASE_URL` from the `.env` parameters — Prisma does not read individual `POSTGRES_*` vars. URL-encode the password if it contains special characters (`!`, `@`, `#`, etc.):
```bash
docker compose -f /opt/infra/apps/shellkeep/compose.yml stop api

# Construct DATABASE_URL from .env (adjust password encoding as needed)
DATABASE_URL="postgresql://USER:PASSWORD@HOST:5432/shellkeep"
docker compose -f /opt/infra/apps/shellkeep/compose.yml run --rm -e DATABASE_URL="${DATABASE_URL}" api npx prisma migrate deploy

docker compose -f /opt/infra/apps/shellkeep/compose.yml start api
```

To re-run seeds (roles, permissions, admin allowlist):
```bash
docker compose -f /opt/infra/apps/shellkeep/compose.yml run --rm -e DATABASE_URL="${DATABASE_URL}" api npx prisma db seed
```

### OAuth callback error
Ensure the Google OAuth redirect URI matches exactly:
```
https://shellkeep.marin.cr/api/auth/google/callback
```

### WebSocket / terminal connection failures
Verify the VPS proxy config includes the `/api/terminal/ws` location block with WebSocket upgrade headers and extended timeouts (3600s for long-lived SSH sessions).

### SSH credential encryption errors
Ensure `ENCRYPTION_KEY` is set in `.env`. Generate with:
```bash
openssl rand -base64 32
```

## Service Management

```bash
# View logs
docker compose -f /opt/infra/apps/shellkeep/compose.yml logs -f api

# View terminal-specific logs
docker compose -f /opt/infra/apps/shellkeep/compose.yml logs -f api | grep -i terminal

# Restart services
docker compose -f /opt/infra/apps/shellkeep/compose.yml restart

# Stop everything
docker compose -f /opt/infra/apps/shellkeep/compose.yml down

# Start everything
docker compose -f /opt/infra/apps/shellkeep/compose.yml up -d
```

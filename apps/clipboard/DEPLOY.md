# Clipboard — Production Deployment Runbook

## Overview

Deploy Clipboard on Ubuntu VPS using the `/opt/infra` infrastructure model.

| Item | Value |
|------|-------|
| **Public URL** | `https://clipboard.marin.cr` |
| **VPS Path** | `/opt/infra/apps/clipboard/` |
| **Repository** | `https://github.com/marinoscar/clipboard.git` |
| **Internal Port** | `127.0.0.1:8320` (Nginx container → VPS proxy) |
| **Database** | SQLite (file-based, inside Docker volume) |
| **File Storage** | AWS S3 |

## Architecture

```
Internet (HTTPS)
  │
  ▼
VPS Nginx Proxy (proxy-nginx, ports 80/443)
  │
  ▼  clipboard.marin.cr → 127.0.0.1:8320
Clipboard Nginx (clipboard-nginx, port 8320)
  ├── /api, /socket.io  → clipboard-api:3000  (NestJS + Fastify)
  └── /                  → clipboard-web:80    (React static build)

clipboard-api → SQLite volume (/data/clipboard.db)
             → AWS S3 (file storage)
```

## Prerequisites

1. Ubuntu VPS with Docker and Docker Compose installed
2. VPS reverse proxy running (`/opt/infra/proxy/`)
3. DNS A record: `clipboard.marin.cr` → VPS IP
4. Google OAuth credentials ([console.cloud.google.com](https://console.cloud.google.com))
   - Authorized redirect URI: `https://clipboard.marin.cr/api/auth/google/callback`
5. AWS S3 bucket with CORS configured for `https://clipboard.marin.cr`

## Step 1: Create Directory Structure

```bash
mkdir -p /opt/infra/apps/clipboard
```

## Step 2: Create Environment File

```bash
nano /opt/infra/apps/clipboard/.env
```

Populate with production values:

```env
# Application
NODE_ENV=production
PORT=3000
APP_URL=https://clipboard.marin.cr

# Database (SQLite - file path inside container)
DATABASE_URL=file:/data/clipboard.db

# JWT Authentication
JWT_SECRET=<generate with: openssl rand -hex 32>
JWT_ACCESS_TTL_MINUTES=15
JWT_REFRESH_TTL_DAYS=14

# Google OAuth
GOOGLE_CLIENT_ID=<your-google-client-id>
GOOGLE_CLIENT_SECRET=<your-google-client-secret>
GOOGLE_CALLBACK_URL=https://clipboard.marin.cr/api/auth/google/callback

# AWS S3 Storage
S3_BUCKET=<your-s3-bucket-name>
S3_REGION=us-east-1
AWS_ACCESS_KEY_ID=<your-aws-access-key>
AWS_SECRET_ACCESS_KEY=<your-aws-secret-key>

# Admin Bootstrap (first user with this email becomes admin)
INITIAL_ADMIN_EMAIL=<your-admin-email>

# Logging
LOG_LEVEL=info
```

## Step 3: Run Install Script

```bash
cd /opt/infra/apps/clipboard
cp repo/infra/deploy/install-clipboard.sh .
chmod +x install-clipboard.sh
./install-clipboard.sh
```

The script will:
1. Clone (or pull) the repository
2. Validate `.env` exists
3. Build Docker images (production targets)
4. Run Prisma migrations on a fresh database
5. Start all services (api, web, nginx)
6. Verify service health

## Step 4: Configure VPS Reverse Proxy

Copy the Nginx config to the VPS proxy:

```bash
cp /opt/infra/apps/clipboard/clipboard.conf /opt/infra/proxy/nginx/conf.d/
```

Validate and reload:

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

## Step 5: Issue TLS Certificate

```bash
certbot certonly \
  --webroot \
  -w /opt/infra/proxy/webroot \
  -d clipboard.marin.cr \
  --config-dir /opt/infra/proxy/letsencrypt
```

Reload the proxy after certificate issuance:

```bash
docker exec proxy-nginx nginx -s reload
```

## Step 6: Verify Deployment

```bash
# Health check
curl https://clipboard.marin.cr/api/health

# Expected response:
# {"data":{"status":"ok","timestamp":"..."},"meta":{"timestamp":"..."}}
```

Open `https://clipboard.marin.cr` in a browser and sign in with Google.

## Updating

To deploy updates:

```bash
cd /opt/infra/apps/clipboard
./install-clipboard.sh
```

The script detects the existing repository and pulls latest changes, rebuilds images, and runs any new migrations.

## Database Backup

```bash
docker cp clipboard-api:/data/clipboard.db /opt/infra/apps/clipboard/backup-$(date +%Y%m%d).db
```

## Troubleshooting

### API won't start
```bash
docker compose -f /opt/infra/apps/clipboard/compose.yml logs api
```

### 502 Bad Gateway
Check that the clipboard containers are running:
```bash
docker compose -f /opt/infra/apps/clipboard/compose.yml ps
```

### Database locked errors
Stop the API before running migrations manually:
```bash
docker compose -f /opt/infra/apps/clipboard/compose.yml stop api
docker compose -f /opt/infra/apps/clipboard/compose.yml run --rm api npx prisma migrate deploy
docker compose -f /opt/infra/apps/clipboard/compose.yml start api
```

### OAuth callback error
Ensure the Google OAuth redirect URI matches exactly:
```
https://clipboard.marin.cr/api/auth/google/callback
```

### WebSocket connection failures
Verify the VPS proxy config includes WebSocket upgrade headers for `/socket.io/`.

## Service Management

```bash
# View logs
docker compose -f /opt/infra/apps/clipboard/compose.yml logs -f api

# Restart services
docker compose -f /opt/infra/apps/clipboard/compose.yml restart

# Stop everything
docker compose -f /opt/infra/apps/clipboard/compose.yml down

# Start everything
docker compose -f /opt/infra/apps/clipboard/compose.yml up -d
```

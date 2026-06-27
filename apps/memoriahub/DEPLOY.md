# MemoriaHub — Production Deployment Runbook

## Overview

Deploy MemoriaHub on the Ubuntu VPS using the `/opt/infra` infrastructure model.

| Item | Value |
|------|-------|
| **Public URL** | `https://memoriahub.marin.cr` |
| **VPS Path** | `/opt/infra/apps/memoriahub/` |
| **Repository** | `https://github.com/marinoscar/MemoriaHub.git` |
| **Internal Port** | `127.0.0.1:8328` (Nginx container -> VPS proxy) |
| **Database** | PostgreSQL at `pgadmin.marin.cr` (SSL, `sslmode=require`) |
| **File Storage** | S3 / Cloudflare R2 |

MemoriaHub is a NestJS + React + Prisma media-management app (photos/videos up
to 10 GB, OAuth login, RBAC, optional AI tagging / face recognition).

## Architecture

```
Internet (HTTPS)
  |
  v
VPS Nginx Proxy (proxy-nginx, ports 80/443)
  |
  v  memoriahub.marin.cr -> 127.0.0.1:8328
MemoriaHub Nginx (memoriahub-nginx, port 8328, nginx.prod.conf)
  |-- /api   -> memoriahub-api:3000  (NestJS + Fastify)
  +-- /      -> memoriahub-web:80    (React static build)

memoriahub-api -> PostgreSQL (pgadmin.marin.cr, SSL)
              -> S3 / R2 (object storage)
```

Three containers on the private `memoriahub-internal` bridge network. There is
no PostgreSQL container — the API connects out to the VPS Postgres over SSL. The
CompreFace face-detection sidecar is intentionally omitted (opt-in later via
Admin Settings).

## Prerequisites

1. Ubuntu VPS with Docker and Docker Compose v2 installed
2. VPS reverse proxy running (`/opt/infra/proxy/`)
3. DNS A record: `memoriahub.marin.cr` -> VPS IP *(already created)*
4. **A `memoriahub` database and user created in pgAdmin** (`pgadmin.marin.cr`)
   before installing — the installer does not create the database
5. Google OAuth credentials ([console.cloud.google.com](https://console.cloud.google.com))
   - Authorized redirect URI: `https://memoriahub.marin.cr/api/auth/google/callback`
6. An S3-compatible bucket (AWS S3 or Cloudflare R2) with credentials, CORS
   configured for `https://memoriahub.marin.cr`

## Step 1: Create Directory Structure

```bash
mkdir -p /opt/infra/apps/memoriahub
```

Copy the install and update scripts in (from this repo) and make them executable:

```bash
cp install-memoriahub.sh update.sh /opt/infra/apps/memoriahub/
cd /opt/infra/apps/memoriahub
chmod +x install-memoriahub.sh update.sh
```

## Step 2: Environment File

You do **not** have to hand-write `.env`. On first run the installer detects
that `.env` is missing and launches an **interactive wizard** that collects every
required value, writes `.env` (chmod 600), and validates it (see
[How it works](#how-it-works)). Just run Step 3.

If you prefer to create it manually (or for CI with `--non-interactive`), copy the
template and fill it in:

```bash
cp repo/infra/compose/.env.example /opt/infra/apps/memoriahub/.env
nano /opt/infra/apps/memoriahub/.env
```

Minimal required values:

```env
NODE_ENV=production
COMPOSE_PROJECT_NAME=memoriahub
APP_URL=https://memoriahub.marin.cr

# Database — VPS Postgres via pgAdmin host, SSL required
POSTGRES_HOST=pgadmin.marin.cr
POSTGRES_PORT=5432
POSTGRES_USER=memoriahub
POSTGRES_PASSWORD=<password>
POSTGRES_DB=memoriahub
POSTGRES_SSL=true

# Secrets (min 32 chars; generate with: openssl rand -base64 32)
JWT_SECRET=<secret>
COOKIE_SECRET=<secret>

# Google OAuth
GOOGLE_CLIENT_ID=<id>
GOOGLE_CLIENT_SECRET=<secret>
GOOGLE_CALLBACK_URL=https://memoriahub.marin.cr/api/auth/google/callback
INITIAL_ADMIN_EMAIL=you@example.com

# Object storage (S3 / R2)
STORAGE_PROVIDER=s3
S3_BUCKET=marin-memoriahub
S3_REGION=<region>
AWS_ACCESS_KEY_ID=<key>
AWS_SECRET_ACCESS_KEY=<secret>
# S3_ENDPOINT=https://<account>.r2.cloudflarestorage.com   # only for R2/MinIO
MAX_FILE_SIZE=10737418240
ALLOWED_MIME_TYPES=image/*,video/*

# Geo (offline reverse geocoding, no network)
GEO_PROVIDER=offline
```

Optional (left disabled): `SECRETS_ENCRYPTION_KEY` (only needed if AI tagging /
face recognition is enabled), `OTEL_*`, `FACE_*`, `AUTO_TAG_*`.

## Step 3: Run Install Script

```bash
cd /opt/infra/apps/memoriahub
./install-memoriahub.sh
```

On a first run this performs the INSTALL flow:
1. Clone the repository
2. Build/validate `.env` (wizard if missing, then Postgres/S3/secret checks)
3. Generate `compose.yml` and `memoriahub.conf`
4. Build Docker images (production targets)
5. Run Prisma migrations **and** seed (roles, permissions, initial admin)
6. Start all services (api, web, nginx)
7. Verify health

## Step 4: Configure VPS Reverse Proxy

```bash
cp /opt/infra/apps/memoriahub/memoriahub.conf /opt/infra/proxy/nginx/conf.d/
```

## Step 5: Issue TLS Certificate

The proxy config references TLS certs, so issue the certificate **before**
reloading Nginx:

```bash
certbot certonly \
  --webroot \
  -w /opt/infra/proxy/webroot \
  -d memoriahub.marin.cr \
  --config-dir /opt/infra/proxy/letsencrypt
```

Then validate and reload the proxy:

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

## Step 6: Verify Deployment

```bash
# Liveness
curl https://memoriahub.marin.cr/api/health/live

# Readiness (includes database connectivity)
curl https://memoriahub.marin.cr/api/health/ready
```

Open `https://memoriahub.marin.cr`, sign in with Google, and confirm the
`INITIAL_ADMIN_EMAIL` user has the Admin role.

## Updating

```bash
cd /opt/infra/apps/memoriahub
./update.sh
```

Or just re-run `./install-memoriahub.sh` — it auto-detects an existing install
and delegates to `update.sh`.

Options:
- `--no-cache` — Force full Docker rebuild (ignores layer cache)
- `--skip-proxy` — Skip the VPS proxy config update/reload

The update pulls latest code, rebuilds images, runs migrations (deploy only — no
seed), and restarts services. With no upstream changes it exits early. Logs are
saved to `./logs/` (last 10 kept); the commit transition is recorded in
`.update-state`.

## Database Backup

MemoriaHub uses the VPS Postgres, which is already included in the nightly
`shared/backup-postgres-to-s3.sh` run (the `memoriahub` database is in its list).
To take an ad-hoc dump:

```bash
pg_dump "host=pgadmin.marin.cr port=5432 dbname=memoriahub user=memoriahub sslmode=require" \
  > /opt/infra/backups/memoriahub-$(date +%Y%m%d).sql
```

---

## How it works

### Install vs. update — decision tree

`install-memoriahub.sh` is the single entry point. It picks a mode automatically:

```
./install-memoriahub.sh
        |
        v
  Is repo/.git AND .env AND compose.yml present?
        |                         |
       NO                        YES
        |                         |
        v                         v
   INSTALL mode             UPDATE mode
   (full first install)     (exec ./update.sh)
        |                         |
        |                         +-- pull latest -> rebuild -> migrate (no seed)
        |                             -> restart -> reload proxy -> health
        |
        +-- clone repo
        +-- .env: wizard (if missing) -> validate
        +-- generate compose.yml + memoriahub.conf
        +-- build images
        +-- migrate + SEED
        +-- start -> health -> print checklist

Overrides:
  --reinstall  force INSTALL (regenerate configs, re-seed)
  --update     force UPDATE  (delegate to ./update.sh)
```

### The `.env` wizard

When `.env` is missing (and not `--non-interactive`), the installer prompts for
each value. Behavior:

- Defaults are shown in `[brackets]`; press Enter to accept.
- `POSTGRES_PASSWORD`, `GOOGLE_CLIENT_SECRET`, and the AWS keys use **masked**
  input (`read -rs`).
- `JWT_SECRET` and `COOKIE_SECRET` are **auto-generated** with
  `openssl rand -base64 32` by default (decline to enter your own).
- `GOOGLE_CALLBACK_URL` is derived automatically from `APP_URL`.
- Inline format checks re-prompt on bad input (email shape, `https://` URLs,
  numeric port / max-size, `true|false` for SSL).
- The file is written with `chmod 600`, a masked summary is shown, and you
  confirm before the install proceeds.

For CI, pass `--non-interactive`: a missing `.env` prints the required keys and
exits instead of prompting.

### Validation pass

After the wizard (or against a hand-edited `.env`, unless `--skip-validate`), the
installer runs best-effort checks. Each prints `[ OK ]`, `[WARN]`, or `[FAIL]`.

| Check | How | Meaning of failure | Fix |
|-------|-----|--------------------|-----|
| Postgres connectivity *(hard)* | `docker run postgres:17-alpine psql … 'SELECT 1'` | host unreachable / auth failed / db missing | check `POSTGRES_*`, create db+user in pgAdmin, verify SSL |
| S3 bucket *(soft)* | `docker run amazon/aws-cli s3 ls s3://$S3_BUCKET` | listing failed (may just be IAM list perms) | verify bucket/region/keys; uploads can still work |
| JWT/COOKIE length *(soft)* | string length | secret shorter than 32 chars | regenerate with `openssl rand -base64 32` |
| Admin email *(soft)* | regex | not an email | fix `INITIAL_ADMIN_EMAIL` |
| OAuth *(reminder)* | n/a | cannot be live-tested | register the callback URL in Google Cloud Console |

Only the Postgres check is **hard**: on failure you are asked
`Continue anyway? [y/N]` (default = abort). All checks are skipped gracefully if
`docker` is not on `PATH`.

### Idempotency & safety

- Re-running the installer/updater is safe. Migrations are additive
  (`prisma migrate deploy`); the **seed runs only on INSTALL / `--reinstall`**,
  never on update.
- The proxy config is only copied/reloaded when it changed, and only after
  `nginx -t` validates it — a bad config never takes down the proxy.
- Update output is teed to `./logs/update-<timestamp>.log` (10 newest kept);
  `.update-state` records the previous/current commit.
- `.env` is never committed and is written `chmod 600`.

### Rollback

To roll back to a previous commit:

```bash
cd /opt/infra/apps/memoriahub/repo
git reset --hard <previous-commit>     # see .update-state for the prior commit
cd /opt/infra/apps/memoriahub
./update.sh --no-cache                 # rebuild from the pinned commit
```

> Note: migrations are forward-only. A rollback that needs a schema change
> reverted must be handled manually against the database.

---

## Troubleshooting

### API won't start
```bash
docker compose -f /opt/infra/apps/memoriahub/compose.yml logs api
```

### 502 Bad Gateway
Check the containers are running:
```bash
docker compose -f /opt/infra/apps/memoriahub/compose.yml ps
```

### Database connection refused / migration errors
The API builds `DATABASE_URL` from the `POSTGRES_*` vars via
`apps/api/scripts/prisma-env.js`, so run migrations through the npm script:
```bash
docker compose -f /opt/infra/apps/memoriahub/compose.yml stop api
docker compose -f /opt/infra/apps/memoriahub/compose.yml run --rm api npm run prisma:migrate
docker compose -f /opt/infra/apps/memoriahub/compose.yml start api
```
Verify `POSTGRES_HOST=pgadmin.marin.cr`, `POSTGRES_SSL=true`, and that the
`memoriahub` database + user exist in pgAdmin. Re-run the validation check:
```bash
./install-memoriahub.sh --reinstall   # re-runs the wizard's validation pass
```

### OAuth callback error
Ensure the Google OAuth redirect URI matches exactly:
```
https://memoriahub.marin.cr/api/auth/google/callback
```

### Uploads fail for large files
Both the VPS proxy (`memoriahub.conf`) and the internal nginx
(`nginx.prod.conf`) set `client_max_body_size 10g`. Confirm `MAX_FILE_SIZE` in
`.env` matches (default `10737418240` = 10 GB). Resumable multipart uploads go
straight to S3 via pre-signed URLs and bypass nginx.

### S3 errors
Verify `S3_BUCKET`, `S3_REGION`, and the AWS keys. For Cloudflare R2, set
`S3_ENDPOINT`. The installer's S3 check only tests `ls` (a list permission);
uploads use object PUT permissions which it does not test.

## Service Management

```bash
# View logs
docker compose -f /opt/infra/apps/memoriahub/compose.yml logs -f api

# Restart services
docker compose -f /opt/infra/apps/memoriahub/compose.yml restart

# Stop everything
docker compose -f /opt/infra/apps/memoriahub/compose.yml down

# Start everything
docker compose -f /opt/infra/apps/memoriahub/compose.yml up -d
```

#!/usr/bin/env bash
# =============================================================================
# install-memoriahub.sh — Install or update MemoriaHub on the VPS
# =============================================================================
# Location on VPS: /opt/infra/apps/memoriahub/install-memoriahub.sh
#
# This is the single smart entry point for MemoriaHub. It decides what to do:
#
#   INSTALL  (first run)  → if the repo, .env, or compose.yml is missing.
#                           Runs the full first-install flow:
#                             1. Create the app directory
#                             2. Clone the MemoriaHub repository
#                             3. Build/validate the .env file
#                                  - if .env is missing, an interactive wizard
#                                    collects every required value and writes it
#                                  - the values are then validated (live Postgres
#                                    connect test, S3 bucket check, secret length)
#                             4. Generate production compose.yml + memoriahub.conf
#                             5. Build the Docker images
#                             6. Run Prisma migrations AND seed (creates roles,
#                                permissions, and the initial admin)
#                             7. Start all services
#                             8. Publish externally: install the VPS proxy vhost,
#                                issue the Let's Encrypt cert, reload the proxy
#                                (skip with --skip-proxy), then verify health
#
#   UPDATE   (already installed) → delegates to ./update.sh, which pulls the
#                           latest code, rebuilds, runs migrations (no seed),
#                           restarts, and reloads the proxy. This keeps one brain
#                           and avoids duplicating the update logic here.
#
# Usage:
#   cd /opt/infra/apps/memoriahub
#   chmod +x install-memoriahub.sh
#   ./install-memoriahub.sh
#
# Options:
#   --reinstall          Force the INSTALL path even if already installed
#                        (regenerates compose.yml/memoriahub.conf, re-runs seed).
#   --update             Force the UPDATE path (delegate to ./update.sh).
#   --non-interactive    Do NOT launch the .env wizard; if .env is missing, print
#                        the required keys and exit (CI-friendly).
#   --skip-validate      Skip the .env validation pass (Postgres/S3/secret checks).
#   --no-cache           Passed through to ./update.sh in UPDATE mode.
#   --skip-proxy         Skip the VPS proxy + TLS step (INSTALL mode) and pass
#                        through to ./update.sh in UPDATE mode.
#   --help, -h           Show this help.
#
# Prerequisites:
#   - Docker and Docker Compose v2 installed
#   - A PostgreSQL database reachable from the VPS (host pgadmin.marin.cr) with a
#     `memoriahub` database + user already created (do this in pgAdmin first)
#   - An S3-compatible bucket (AWS S3 / Cloudflare R2) with credentials
#   - A Google OAuth client (callback https://memoriahub.marin.cr/api/auth/google/callback)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
MEMORIAHUB_DIR="/opt/infra/apps/memoriahub"
REPO_DIR="${MEMORIAHUB_DIR}/repo"
REPO_URL="https://github.com/marinoscar/MemoriaHub.git"
BRANCH="main"
DOMAIN="memoriahub.marin.cr"
HOST_PORT="8328"
ENV_FILE="${MEMORIAHUB_DIR}/.env"
ENV_EXAMPLE="${REPO_DIR}/infra/compose/.env.example"
COMPOSE_FILE="${MEMORIAHUB_DIR}/compose.yml"

# VPS reverse proxy + TLS (Let's Encrypt) — used to publish the app externally
PROXY_DIR="/opt/infra/proxy"
PROXY_CONF_DST="${PROXY_DIR}/nginx/conf.d/memoriahub.conf"
PROXY_WEBROOT="${PROXY_DIR}/webroot"           # mounted into proxy as /var/www/certbot
LETSENCRYPT_DIR="${PROXY_DIR}/letsencrypt"     # mounted into proxy as /etc/letsencrypt
CERT_EMAIL="oscar@marin.cr"                    # only used when registering a new ACME account

# The app's production image (apps/api/Dockerfile) does NOT copy prisma.config.ts,
# but Prisma 7 reads the datasource url from that file. The running app is fine
# (it sets DATABASE_URL programmatically), but the Prisma CLI used for migrate/seed
# needs the config — so we bind-mount it for those one-off `compose run` commands.
PRISMA_CONFIG_SRC="${REPO_DIR}/apps/api/prisma.config.ts"

# Options / mode
FORCE_MODE=""            # "", "install", or "update"
NON_INTERACTIVE=false
SKIP_VALIDATE=false
SKIP_PROXY=false
PASSTHRU=()              # forwarded to update.sh in UPDATE mode

log()  { echo "[memoriahub] $*"; }
pass() { echo "  [ OK ]  $*"; }
warn() { echo "  [WARN]  $*"; }
fail() { echo "  [FAIL]  $*"; }

show_help() {
    # Print the header comment block (everything up to `set -euo pipefail`).
    sed -n '2,/^set -euo pipefail/{/^set -euo pipefail/d;p;}' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
for arg in "$@"; do
    case "${arg}" in
        --reinstall)       FORCE_MODE="install" ;;
        --update)          FORCE_MODE="update" ;;
        --non-interactive) NON_INTERACTIVE=true ;;
        --skip-validate)   SKIP_VALIDATE=true ;;
        --no-cache)        PASSTHRU+=("--no-cache") ;;
        --skip-proxy)      SKIP_PROXY=true; PASSTHRU+=("--skip-proxy") ;;
        --help|-h)         show_help; exit 0 ;;
        *)                 log "Unknown option: ${arg}"; show_help; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers — interactive prompting
# ---------------------------------------------------------------------------

# ask VARNAME "Prompt text" ["default"]
# Prompts until a non-empty value is given; accepts a default on empty input.
ask() {
    local __var="$1" __prompt="$2" __default="${3:-}" __input=""
    while true; do
        if [ -n "${__default}" ]; then
            read -rp "  ${__prompt} [${__default}]: " __input || true
            __input="${__input:-${__default}}"
        else
            read -rp "  ${__prompt}: " __input || true
        fi
        if [ -z "${__input}" ]; then
            echo "    ! a value is required"
            continue
        fi
        printf -v "${__var}" '%s' "${__input}"
        break
    done
}

# ask_secret VARNAME "Prompt text" [min_len]
# Masked input; re-prompts until non-empty and >= min_len (if given).
ask_secret() {
    local __var="$1" __prompt="$2" __min="${3:-1}" __input=""
    while true; do
        read -rsp "  ${__prompt}: " __input || true
        echo
        if [ -z "${__input}" ]; then
            echo "    ! a value is required"
            continue
        fi
        if [ "${#__input}" -lt "${__min}" ]; then
            echo "    ! must be at least ${__min} characters"
            continue
        fi
        printf -v "${__var}" '%s' "${__input}"
        break
    done
}

# confirm "Question" ["y"|"n" default]  → returns 0 for yes, 1 for no
confirm() {
    local __q="$1" __default="${2:-n}" __reply="" __hint="[y/N]"
    [ "${__default}" = "y" ] && __hint="[Y/n]"
    read -rp "  ${__q} ${__hint}: " __reply || true
    __reply="${__reply:-${__default}}"
    [[ "${__reply}" =~ ^[Yy] ]]
}

# read_env KEY  → echoes the literal value for KEY from ${ENV_FILE}
# (does not source the file, so passwords with special characters are safe)
read_env() {
    local __key="$1" __val=""
    __val=$(grep -E "^${__key}=" "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2-)
    # strip one layer of surrounding quotes if a user added them by hand
    __val="${__val%\"}"; __val="${__val#\"}"
    __val="${__val%\'}"; __val="${__val#\'}"
    printf '%s' "${__val}"
}

print_required_keys() {
    log ""
    log "  No .env file found at ${ENV_FILE}"
    log ""
    log "  Create it from the template and fill in the values:"
    log "    cp ${ENV_EXAMPLE} ${ENV_FILE}"
    log "    nano ${ENV_FILE}"
    log ""
    log "  Required values:"
    log "    NODE_ENV=production"
    log "    APP_URL=https://${DOMAIN}"
    log "    POSTGRES_HOST=pgadmin.marin.cr   POSTGRES_PORT=5432"
    log "    POSTGRES_DB=memoriahub  POSTGRES_USER=memoriahub  POSTGRES_PASSWORD=..."
    log "    POSTGRES_SSL=true"
    log "    JWT_SECRET (openssl rand -base64 32)"
    log "    COOKIE_SECRET (openssl rand -base64 32)"
    log "    SECRETS_ENCRYPTION_KEY (openssl rand -base64 32; base64 of exactly 32 bytes)"
    log "    GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET"
    log "    GOOGLE_CALLBACK_URL=https://${DOMAIN}/api/auth/google/callback"
    log "    INITIAL_ADMIN_EMAIL=you@example.com"
    log "    STORAGE_PROVIDER=s3  S3_BUCKET  S3_REGION"
    log "    AWS_ACCESS_KEY_ID  AWS_SECRET_ACCESS_KEY"
    log ""
    log "  Then run this script again."
}

# ---------------------------------------------------------------------------
# Interactive .env wizard
# ---------------------------------------------------------------------------
run_env_wizard() {
    log ""
    log "No .env found — let's create one. Press Enter to accept a [default]."
    log ""

    local APP_URL POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER
    local POSTGRES_PASSWORD POSTGRES_SSL JWT_SECRET COOKIE_SECRET SECRETS_ENCRYPTION_KEY
    local GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GOOGLE_CALLBACK_URL
    local INITIAL_ADMIN_EMAIL STORAGE_PROVIDER S3_BUCKET S3_REGION S3_ENDPOINT
    local AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY MAX_FILE_SIZE GEO_PROVIDER

    # --- Application ---
    echo "  --- Application ---"
    while true; do
        ask APP_URL "Public app URL" "https://${DOMAIN}"
        [[ "${APP_URL}" == https://* ]] && break
        echo "    ! must start with https://"
    done
    APP_URL="${APP_URL%/}"
    GOOGLE_CALLBACK_URL="${APP_URL}/api/auth/google/callback"
    echo "  OAuth callback will be: ${GOOGLE_CALLBACK_URL}"
    echo

    # --- Database ---
    echo "  --- Database (PostgreSQL) ---"
    echo "  Create the database + user in pgAdmin (pgadmin.marin.cr) first."
    ask POSTGRES_HOST "Postgres host" "pgadmin.marin.cr"
    while true; do
        ask POSTGRES_PORT "Postgres port" "5432"
        [[ "${POSTGRES_PORT}" =~ ^[0-9]+$ ]] && break
        echo "    ! must be numeric"
    done
    ask POSTGRES_DB   "Postgres database name" "memoriahub"
    ask POSTGRES_USER "Postgres user" "memoriahub"
    ask_secret POSTGRES_PASSWORD "Postgres password"
    while true; do
        ask POSTGRES_SSL "Use SSL (sslmode=require)? true/false" "true"
        [[ "${POSTGRES_SSL}" == "true" || "${POSTGRES_SSL}" == "false" ]] && break
        echo "    ! enter true or false"
    done
    echo

    # --- Secrets ---
    # SECRETS_ENCRYPTION_KEY is the AES-256-GCM key used to encrypt provider
    # credentials at rest (storage / AI / face / geo). The API rejects it unless
    # it base64-decodes to EXACTLY 32 bytes, so we generate/validate it strictly.
    echo "  --- Secrets ---"
    if confirm "Auto-generate JWT_SECRET, COOKIE_SECRET, and SECRETS_ENCRYPTION_KEY with openssl?" "y"; then
        JWT_SECRET="$(openssl rand -base64 32)"
        COOKIE_SECRET="$(openssl rand -base64 32)"
        SECRETS_ENCRYPTION_KEY="$(openssl rand -base64 32)"
        echo "  Generated JWT_SECRET, COOKIE_SECRET, and SECRETS_ENCRYPTION_KEY."
    else
        ask_secret JWT_SECRET    "JWT secret (min 32 chars)"    32
        ask_secret COOKIE_SECRET "Cookie secret (min 32 chars)" 32
        while true; do
            ask_secret SECRETS_ENCRYPTION_KEY "Secrets encryption key (base64 of 32 bytes; openssl rand -base64 32)"
            if [ "$(printf '%s' "${SECRETS_ENCRYPTION_KEY}" | base64 -d 2>/dev/null | wc -c)" = "32" ]; then
                break
            fi
            echo "    ! must be base64 that decodes to exactly 32 bytes — generate with: openssl rand -base64 32"
        done
    fi
    echo

    # --- Google OAuth ---
    echo "  --- Google OAuth ---"
    ask        GOOGLE_CLIENT_ID     "Google OAuth Client ID"
    ask_secret GOOGLE_CLIENT_SECRET "Google OAuth Client Secret"
    while true; do
        ask INITIAL_ADMIN_EMAIL "Initial admin email" "${USER_EMAIL_DEFAULT:-}"
        [[ "${INITIAL_ADMIN_EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && break
        echo "    ! not a valid email address"
    done
    echo

    # --- Storage (S3 / R2) ---
    echo "  --- Object storage (S3 / Cloudflare R2) ---"
    STORAGE_PROVIDER="s3"
    ask        S3_BUCKET            "S3 bucket name" "marin-memoriahub"
    ask        S3_REGION            "S3 region" "us-east-1"
    ask_secret AWS_ACCESS_KEY_ID    "AWS access key id"
    ask_secret AWS_SECRET_ACCESS_KEY "AWS secret access key"
    read -rp "  S3 endpoint URL (blank for AWS S3; set for R2/MinIO): " S3_ENDPOINT || true
    while true; do
        ask MAX_FILE_SIZE "Max upload size in bytes" "10737418240"
        [[ "${MAX_FILE_SIZE}" =~ ^[0-9]+$ ]] && break
        echo "    ! must be numeric"
    done
    GEO_PROVIDER="offline"
    echo

    # --- Write .env (values are written literally; env_file is not interpolated) ---
    umask 077
    cat > "${ENV_FILE}" <<EOF
# =============================================================================
# MemoriaHub production environment
# Generated by install-memoriahub.sh — edit by hand and re-run to re-validate.
# Never commit this file.
# =============================================================================

NODE_ENV=production
COMPOSE_PROJECT_NAME=memoriahub
APP_URL=${APP_URL}

# --- Database (PostgreSQL via pgAdmin host, SSL) ---
POSTGRES_HOST=${POSTGRES_HOST}
POSTGRES_PORT=${POSTGRES_PORT}
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_SSL=${POSTGRES_SSL}

# --- Secrets ---
JWT_SECRET=${JWT_SECRET}
COOKIE_SECRET=${COOKIE_SECRET}
# AES-256-GCM key (base64, 32 bytes) for encrypting stored provider credentials
# (storage / AI / face / geo). Generate with: openssl rand -base64 32
SECRETS_ENCRYPTION_KEY=${SECRETS_ENCRYPTION_KEY}

# --- Google OAuth ---
GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}
GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET}
GOOGLE_CALLBACK_URL=${GOOGLE_CALLBACK_URL}
INITIAL_ADMIN_EMAIL=${INITIAL_ADMIN_EMAIL}

# --- Object storage ---
STORAGE_PROVIDER=${STORAGE_PROVIDER}
S3_BUCKET=${S3_BUCKET}
S3_REGION=${S3_REGION}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
$( [ -n "${S3_ENDPOINT}" ] && echo "S3_ENDPOINT=${S3_ENDPOINT}" )
MAX_FILE_SIZE=${MAX_FILE_SIZE}
ALLOWED_MIME_TYPES=image/*,video/*

# --- Geo (offline reverse geocoding, no network) ---
GEO_PROVIDER=${GEO_PROVIDER}

# --- Optional features (disabled by default; see infra/compose/.env.example) ---
# OTEL_ENABLED=false
EOF
    umask 022
    chmod 600 "${ENV_FILE}"

    echo
    log "Wrote ${ENV_FILE} (chmod 600). Summary (secrets masked):"
    echo "    APP_URL=${APP_URL}"
    echo "    POSTGRES_HOST=${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB} (user=${POSTGRES_USER}, ssl=${POSTGRES_SSL})"
    echo "    POSTGRES_PASSWORD=********"
    echo "    JWT_SECRET=********  COOKIE_SECRET=********  SECRETS_ENCRYPTION_KEY=********"
    echo "    GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}"
    echo "    GOOGLE_CLIENT_SECRET=********"
    echo "    INITIAL_ADMIN_EMAIL=${INITIAL_ADMIN_EMAIL}"
    echo "    S3_BUCKET=${S3_BUCKET}  S3_REGION=${S3_REGION}${S3_ENDPOINT:+  S3_ENDPOINT=${S3_ENDPOINT}}"
    echo "    MAX_FILE_SIZE=${MAX_FILE_SIZE}"
    echo
    if ! confirm "Continue with these values?" "y"; then
        log "Aborted by user. Edit ${ENV_FILE} (nano) and re-run, or re-run to redo the wizard."
        rm -f "${ENV_FILE}"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Validation pass — best-effort, gated on tool availability
# ---------------------------------------------------------------------------
validate_env() {
    if [ "${SKIP_VALIDATE}" = "true" ]; then
        log "Skipping .env validation (--skip-validate)."
        return 0
    fi

    log ""
    log "Validating .env values..."
    local hard_fail=false

    local pg_host pg_port pg_db pg_user pg_pass pg_ssl
    local jwt cookie seckey bucket region endpoint akid asecret admin
    pg_host=$(read_env POSTGRES_HOST)
    pg_port=$(read_env POSTGRES_PORT)
    pg_db=$(read_env POSTGRES_DB)
    pg_user=$(read_env POSTGRES_USER)
    pg_pass=$(read_env POSTGRES_PASSWORD)
    pg_ssl=$(read_env POSTGRES_SSL)
    jwt=$(read_env JWT_SECRET)
    cookie=$(read_env COOKIE_SECRET)
    seckey=$(read_env SECRETS_ENCRYPTION_KEY)
    bucket=$(read_env S3_BUCKET)
    region=$(read_env S3_REGION)
    endpoint=$(read_env S3_ENDPOINT)
    akid=$(read_env AWS_ACCESS_KEY_ID)
    asecret=$(read_env AWS_SECRET_ACCESS_KEY)
    admin=$(read_env INITIAL_ADMIN_EMAIL)

    # --- Secret strength ---
    if [ "${#jwt}" -ge 32 ]; then pass "JWT_SECRET length OK"; else warn "JWT_SECRET is shorter than 32 chars"; fi
    if [ "${#cookie}" -ge 32 ]; then pass "COOKIE_SECRET length OK"; else warn "COOKIE_SECRET is shorter than 32 chars"; fi

    # --- Secrets encryption key (must base64-decode to EXACTLY 32 bytes) ---
    # The API throws "SECRETS_ENCRYPTION_KEY must be a base64-encoded 32-byte key"
    # the first time it encrypts a stored credential, so we treat this as a hard fail.
    local seckey_bytes
    seckey_bytes=$(printf '%s' "${seckey}" | base64 -d 2>/dev/null | wc -c)
    if [ "${seckey_bytes}" = "32" ]; then
        pass "SECRETS_ENCRYPTION_KEY is a valid 32-byte base64 key"
    else
        fail "SECRETS_ENCRYPTION_KEY must base64-decode to 32 bytes (got ${seckey_bytes})."
        echo "        → generate with: openssl rand -base64 32"
        hard_fail=true
    fi

    # --- Admin email format ---
    if [[ "${admin}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
        pass "INITIAL_ADMIN_EMAIL looks valid"
    else
        warn "INITIAL_ADMIN_EMAIL does not look like an email: ${admin}"
    fi

    # --- Postgres connectivity (hard check) ---
    if command -v docker >/dev/null 2>&1; then
        local sslmode="disable"
        [ "${pg_ssl}" = "true" ] && sslmode="require"
        local conninfo="host=${pg_host} port=${pg_port} dbname=${pg_db} user=${pg_user} sslmode=${sslmode} connect_timeout=10"
        local pg_out=""
        if pg_out=$(docker run --rm -e PGPASSWORD="${pg_pass}" postgres:17-alpine \
                psql -v ON_ERROR_STOP=1 "${conninfo}" -tAc 'SELECT 1' 2>&1); then
            pass "Postgres connection OK (${pg_host}:${pg_port}/${pg_db}, sslmode=${sslmode})"
        else
            fail "Postgres connection FAILED (${pg_host}:${pg_port}/${pg_db}, sslmode=${sslmode})"
            echo "${pg_out}" | sed 's/^/        /'
            case "${pg_out}" in
                *"password authentication"*) echo "        → wrong POSTGRES_USER/POSTGRES_PASSWORD" ;;
                *"does not exist"*)           echo "        → create the database/user in pgAdmin first" ;;
                *"could not translate"*|*"could not connect"*|*"timeout"*)
                                              echo "        → host unreachable or wrong POSTGRES_HOST/PORT/SSL" ;;
            esac
            hard_fail=true
        fi
    else
        warn "docker not found — skipping live Postgres connectivity test"
    fi

    # --- S3 bucket reachability (soft check) ---
    if command -v docker >/dev/null 2>&1 && [ -n "${bucket}" ]; then
        local endpoint_args=()
        [ -n "${endpoint}" ] && endpoint_args=(--endpoint-url "${endpoint}")
        if docker run --rm \
                -e AWS_ACCESS_KEY_ID="${akid}" \
                -e AWS_SECRET_ACCESS_KEY="${asecret}" \
                -e AWS_DEFAULT_REGION="${region:-us-east-1}" \
                amazon/aws-cli s3 ls "s3://${bucket}" ${endpoint_args[@]+"${endpoint_args[@]}"} >/dev/null 2>&1; then
            pass "S3 bucket reachable (${bucket})"
        else
            warn "S3 check failed for bucket '${bucket}' — listing may be restricted by IAM."
            warn "Verify S3_BUCKET / S3_REGION / keys (uploads can still work without list perms)."
        fi
    fi

    # --- OAuth reminder (cannot validate a client secret without a full flow) ---
    warn "OAuth not live-tested. Ensure this callback is registered in Google Cloud Console:"
    echo "        $(read_env GOOGLE_CALLBACK_URL)"

    if [ "${hard_fail}" = "true" ]; then
        log ""
        if ! confirm "Validation reported HARD failures. Continue anyway?" "n"; then
            log "Aborting. Fix ${ENV_FILE} (nano) and re-run."
            exit 1
        fi
        log "Continuing despite validation failures (user override)."
    else
        log "Validation passed."
    fi
}

# ---------------------------------------------------------------------------
# Generators — compose.yml and the VPS proxy config
# ---------------------------------------------------------------------------
generate_compose() {
    cat > "${COMPOSE_FILE}" <<COMPOSE_EOF
# =============================================================================
# MemoriaHub — Production Docker Compose
# =============================================================================
# Generated by install-memoriahub.sh
# Do not edit manually — re-run the installer (or --reinstall) to regenerate.
#
# Services:
#   nginx           internal reverse proxy, binds 127.0.0.1:${HOST_PORT} (the VPS proxy routes here)
#   api             NestJS + Fastify backend (connects to PostgreSQL via .env; SSL per POSTGRES_SSL)
#   web             React frontend, static build served by nginx on :80
#   compreface-core keyless face-detection sidecar; the API reaches it at
#                   http://compreface-core:3000 over the shared internal network.
# =============================================================================

services:
  # ---------------------------------------------------------------------------
  # Nginx — Internal reverse proxy (routes /api -> api, / -> web)
  # ---------------------------------------------------------------------------
  nginx:
    container_name: memoriahub-nginx
    image: nginx:alpine
    ports:
      - "127.0.0.1:${HOST_PORT}:80"
    volumes:
      - ./repo/infra/nginx/nginx.prod.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      - api
      - web
    restart: unless-stopped
    networks:
      - memoriahub-internal

  # ---------------------------------------------------------------------------
  # API — NestJS Backend (Fastify) + Prisma
  # ---------------------------------------------------------------------------
  api:
    container_name: memoriahub-api
    build:
      context: ./repo/apps/api
      dockerfile: Dockerfile
      target: production
    env_file:
      - .env
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: '1.0'
    networks:
      - memoriahub-internal

  # ---------------------------------------------------------------------------
  # Web — React Frontend (static build served by Nginx on :80)
  # ---------------------------------------------------------------------------
  web:
    container_name: memoriahub-web
    build:
      context: ./repo/apps/web
      dockerfile: Dockerfile
      target: production
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 128M
    networks:
      - memoriahub-internal

  # ---------------------------------------------------------------------------
  # CompreFace core — keyless face-detection sidecar (the \`compreface\` face
  # provider). Stateless: no database, no API key, no admin UI, no exposed
  # ports. The API resolves it by name at http://compreface-core:3000
  # (override with FACE_COMPREFACE_URL). Health endpoint: GET /status.
  # Both this container and the API must share memoriahub-internal so the name
  # resolves — that is what makes face detection's "Test connection" work.
  # ---------------------------------------------------------------------------
  compreface-core:
    container_name: compreface-core
    image: exadel/compreface-core:1.2.0-mobilenet
    environment:
      - UWSGI_PROCESSES=1   # single worker — tuned for a shared-CPU VPS
      - UWSGI_THREADS=1
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 2G
    networks:
      - memoriahub-internal

# =============================================================================
# Networks
# =============================================================================
networks:
  memoriahub-internal:
    driver: bridge
COMPOSE_EOF
    log "  compose.yml generated."
}

generate_proxy_conf() {
    cat > "${MEMORIAHUB_DIR}/memoriahub.conf" <<NGINX_EOF
# =============================================================================
# ${DOMAIN} — VPS Reverse Proxy Config
# =============================================================================
# Generated by install-memoriahub.sh
# Copy to: /opt/infra/proxy/nginx/conf.d/memoriahub.conf
# =============================================================================

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    # Large photo/video uploads (matches MAX_FILE_SIZE and the internal nginx)
    client_max_body_size 10g;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # API routes -> NestJS backend (generous timeouts for big multipart uploads)
    location /api {
        proxy_pass http://127.0.0.1:${HOST_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
        proxy_request_buffering off;
    }

    # Frontend (React SPA)
    location / {
        proxy_pass http://127.0.0.1:${HOST_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

# HTTP -> HTTPS redirect
server {
    listen 80;
    server_name ${DOMAIN};

    # ACME challenge (Let's Encrypt)
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$server_name\$request_uri;
    }
}
NGINX_EOF
    log "  memoriahub.conf generated."
}

# ---------------------------------------------------------------------------
# Prisma CLI runner — runs a one-off `npm run <script>` in the api service with
# prisma.config.ts bind-mounted (the production image omits it; see note above).
# Usage: prisma_cli prisma:migrate   /   prisma_cli prisma:seed
# ---------------------------------------------------------------------------
prisma_cli() {
    local script="$1"
    local mount=()
    if [ -f "${PRISMA_CONFIG_SRC}" ]; then
        mount=(-v "${PRISMA_CONFIG_SRC}:/app/prisma.config.ts:ro")
    else
        warn "prisma.config.ts not found at ${PRISMA_CONFIG_SRC};"
        warn "Prisma CLI may fail. Has the repo been cloned?"
    fi
    docker compose run --rm -T ${mount[@]+"${mount[@]}"} api npm run "${script}"
}

# ---------------------------------------------------------------------------
# Publish externally — install the VPS proxy vhost + issue/serve the TLS cert.
# Idempotent: skips cert issuance if one already exists; rolls back the vhost if
# the shared proxy fails validation so we never leave it in a broken state.
# ---------------------------------------------------------------------------
setup_proxy_and_tls() {
    if [ "${SKIP_PROXY}" = "true" ]; then
        log "  Skipping proxy + TLS setup (--skip-proxy)."
        return 0
    fi
    if [ ! -d "$(dirname "${PROXY_CONF_DST}")" ]; then
        warn "VPS proxy not found at ${PROXY_DIR} — skipping proxy + TLS."
        warn "Set up the proxy, then copy ${MEMORIAHUB_DIR}/memoriahub.conf manually."
        return 0
    fi

    # 1. Issue the TLS certificate FIRST. The vhost references it, so nginx -t
    #    fails if it is missing. The proxy's default :80 server already serves
    #    /.well-known/acme-challenge from /var/www/certbot, so no vhost is needed
    #    yet. We use the same certbot Docker image + container paths as the
    #    nightly renew script so the renewal config it writes stays consistent.
    if [ -f "${LETSENCRYPT_DIR}/live/${DOMAIN}/fullchain.pem" ]; then
        pass "TLS certificate already present for ${DOMAIN}."
    else
        log "  Issuing Let's Encrypt certificate for ${DOMAIN}..."
        if docker run --rm \
                -v "${LETSENCRYPT_DIR}:/etc/letsencrypt" \
                -v "${PROXY_WEBROOT}:/var/www/certbot" \
                certbot/certbot:latest certonly \
                    --webroot -w /var/www/certbot \
                    -d "${DOMAIN}" \
                    --key-type ecdsa \
                    --non-interactive --agree-tos -m "${CERT_EMAIL}"; then
            pass "Certificate issued for ${DOMAIN}."
        else
            fail "Certificate issuance failed for ${DOMAIN}."
            warn "Check DNS (A record -> this host) and that proxy-nginx serves :80, then re-run."
            return 0
        fi
    fi

    # 2. Install the vhost into the shared proxy.
    cp "${MEMORIAHUB_DIR}/memoriahub.conf" "${PROXY_CONF_DST}"
    log "  Proxy vhost copied to ${PROXY_CONF_DST}."

    # 3. Validate + reload. If validation fails, remove the vhost we just added so
    #    the running proxy keeps serving every other site unchanged.
    if docker exec proxy-nginx nginx -t >/dev/null 2>&1; then
        docker exec proxy-nginx nginx -s reload >/dev/null 2>&1
        pass "VPS proxy validated and reloaded."
    else
        fail "Proxy nginx validation FAILED — rolling back the memoriahub vhost."
        rm -f "${PROXY_CONF_DST}"
        docker exec proxy-nginx nginx -t 2>&1 | sed 's/^/        /' || true
        warn "The proxy was left unchanged. Fix the issue and re-run."
    fi
}

# ---------------------------------------------------------------------------
# Mode detection
# ---------------------------------------------------------------------------
detect_mode() {
    if [ -n "${FORCE_MODE}" ]; then
        echo "${FORCE_MODE}"
        return
    fi
    if [ -d "${REPO_DIR}/.git" ] && [ -f "${ENV_FILE}" ] && [ -f "${COMPOSE_FILE}" ]; then
        echo "update"
    else
        echo "install"
    fi
}

install_reason() {
    if [ ! -d "${REPO_DIR}/.git" ]; then echo "repo not cloned yet"
    elif [ ! -f "${ENV_FILE}" ];   then echo "no .env found"
    elif [ ! -f "${COMPOSE_FILE}" ]; then echo "compose.yml not generated yet"
    else echo "forced by --reinstall"; fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
mkdir -p "${MEMORIAHUB_DIR}"

MODE="$(detect_mode)"

if [ "${MODE}" = "update" ]; then
    log "============================================"
    log " MemoriaHub Installer"
    log "============================================"
    log "Mode: UPDATE (existing install detected)"
    if [ ! -x "${MEMORIAHUB_DIR}/update.sh" ]; then
        log "ERROR: ${MEMORIAHUB_DIR}/update.sh not found or not executable."
        log "Copy update.sh next to this script (chmod +x update.sh), or use --reinstall."
        exit 1
    fi
    log "Delegating to update.sh ${PASSTHRU[*]:-}"
    if [ "${#PASSTHRU[@]}" -gt 0 ]; then
        exec "${MEMORIAHUB_DIR}/update.sh" "${PASSTHRU[@]}"
    else
        exec "${MEMORIAHUB_DIR}/update.sh"
    fi
fi

log "============================================"
log " MemoriaHub Installer"
log "============================================"
log "Mode: INSTALL ($(install_reason))"
log ""

# --- Step 1: directories ---
log "[1/7] Setting up directories..."
log "  ${MEMORIAHUB_DIR} ready."

# --- Step 2: clone or pull the repository ---
log ""
log "[2/7] Fetching source code..."
if [ -d "${REPO_DIR}/.git" ]; then
    log "  Repository exists. Pulling latest from ${BRANCH}..."
    git -C "${REPO_DIR}" fetch origin
    git -C "${REPO_DIR}" reset --hard "origin/${BRANCH}"
    log "  Updated to latest."
else
    log "  Cloning from ${REPO_URL}..."
    git clone --branch "${BRANCH}" "${REPO_URL}" "${REPO_DIR}"
    log "  Clone complete."
fi

# --- Step 3: environment file (wizard + validation) ---
log ""
log "[3/7] Preparing environment file..."
if [ -f "${ENV_FILE}" ]; then
    log "  .env found at ${ENV_FILE}."
else
    if [ "${NON_INTERACTIVE}" = "true" ]; then
        print_required_keys
        exit 1
    fi
    run_env_wizard
fi
validate_env

# --- Step 4: generate production config ---
log ""
log "[4/7] Generating production configuration..."
generate_compose
generate_proxy_conf

# --- Step 5: build images, run migrations + seed ---
log ""
log "[5/8] Building images..."
cd "${MEMORIAHUB_DIR}"
docker compose build
log "  Images built."

log ""
log "  Running database migrations..."
# prisma-env.js (apps/api/scripts/) builds DATABASE_URL from the POSTGRES_* vars
# in .env (including sslmode=require when POSTGRES_SSL=true). prisma_cli also
# bind-mounts prisma.config.ts (which the production image omits) so the CLI can
# read the datasource url under Prisma 7.
prisma_cli prisma:migrate
log "  Migrations complete."

log "  Running database seed (roles, permissions, initial admin)..."
prisma_cli prisma:seed
log "  Seed complete."

# --- Step 6: start services ---
log ""
log "[6/8] Starting all services..."
docker compose up -d
log "  All containers started."

log "  Waiting for API to initialize..."
API_READY=false
for _ in $(seq 1 60); do
    if docker exec memoriahub-api wget -qO- http://127.0.0.1:3000/api/health/live >/dev/null 2>&1; then
        API_READY=true
        break
    fi
    sleep 2
done
if [ "${API_READY}" = "false" ]; then
    log "  WARNING: API health check did not pass within 120 seconds."
    log "  Check logs: docker compose -f ${COMPOSE_FILE} logs api"
fi

# --- Step 7: publish externally (proxy vhost + TLS cert) ---
log ""
log "[7/8] Publishing externally (VPS proxy + TLS)..."
setup_proxy_and_tls

# --- Step 8: verify health ---
log ""
log "[8/8] Verifying services..."
sleep 3
RUNNING=$(docker compose ps --format '{{.Name}}' 2>/dev/null | wc -l)
log "  Containers running: ${RUNNING}"
API_STATUS=$(docker exec memoriahub-api wget -qO- http://127.0.0.1:3000/api/health/live 2>/dev/null || echo "FAIL")
if echo "${API_STATUS}" | grep -qi "ok\|status\|healthy"; then
    log "  API health (internal):  OK"
else
    log "  API health (internal):  WARN (response: ${API_STATUS})"
    log "                          Check: docker compose -f ${COMPOSE_FILE} logs api"
fi

# CompreFace sidecar — the face-detection backend. Verify the api can resolve
# and reach it on the shared network (this is what the Face Settings "Test
# connection" exercises). Best-effort: it loads ML models on boot, so allow a
# short grace window before warning.
CF_OK=false
for _ in $(seq 1 20); do
    if docker exec memoriahub-api wget -qO- http://compreface-core:3000/status 2>/dev/null | grep -qi '"status":"ok"'; then
        CF_OK=true
        break
    fi
    sleep 3
done
if [ "${CF_OK}" = "true" ]; then
    log "  CompreFace:             OK (api -> http://compreface-core:3000)"
else
    log "  CompreFace:             WARN — api could not reach the face-detection sidecar."
    log "                          Check: docker compose -f ${COMPOSE_FILE} logs compreface-core"
fi

# External end-to-end check through the VPS proxy over HTTPS (best-effort).
if [ "${SKIP_PROXY}" != "true" ] && command -v curl >/dev/null 2>&1; then
    EXT_STATUS=$(curl -sS --max-time 15 "https://${DOMAIN}/api/health/live" 2>/dev/null || echo "FAIL")
    if echo "${EXT_STATUS}" | grep -qi '"status":"ok"\|ok'; then
        log "  API health (https):     OK (https://${DOMAIN})"
    else
        log "  API health (https):     WARN — not reachable via https yet."
        log "                          Check DNS, the proxy vhost, and the TLS cert."
    fi
fi

log ""
log "============================================"
log " MemoriaHub installation complete!"
log "============================================"
log ""
log " Internal URL: http://127.0.0.1:${HOST_PORT}"
log " External URL: https://${DOMAIN}"
log ""
if [ "${SKIP_PROXY}" = "true" ]; then
    log " Proxy + TLS were SKIPPED (--skip-proxy). To publish externally:"
    log "   1. cp ${MEMORIAHUB_DIR}/memoriahub.conf ${PROXY_CONF_DST}"
    log "   2. Issue the cert (same image/paths as the nightly renew script):"
    log "      docker run --rm -v ${LETSENCRYPT_DIR}:/etc/letsencrypt \\"
    log "        -v ${PROXY_WEBROOT}:/var/www/certbot certbot/certbot:latest \\"
    log "        certonly --webroot -w /var/www/certbot -d ${DOMAIN} --key-type ecdsa"
    log "   3. docker exec proxy-nginx nginx -t && docker exec proxy-nginx nginx -s reload"
    log ""
fi
log " Remaining manual step (one-time):"
log "   • Register the Google OAuth redirect URI in Google Cloud Console:"
log "       https://${DOMAIN}/api/auth/google/callback"
log ""
log " Verify:  curl https://${DOMAIN}/api/health/live"
log ""
log " To update later, just run ./install-memoriahub.sh again (it auto-detects"
log " UPDATE mode) or ./update.sh directly."
log "============================================"

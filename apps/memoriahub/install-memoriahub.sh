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
#                             7. Start all services and verify health
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
#   --skip-proxy         Passed through to ./update.sh in UPDATE mode.
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

# Options / mode
FORCE_MODE=""            # "", "install", or "update"
NON_INTERACTIVE=false
SKIP_VALIDATE=false
PASSTHRU=()              # forwarded to update.sh in UPDATE mode

log()  { echo "[memoriahub] $*"; }
pass() { echo "  [ OK ]  $*"; }
warn() { echo "  [WARN]  $*"; }
fail() { echo "  [FAIL]  $*"; }

show_help() {
    sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'
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
        --skip-proxy)      PASSTHRU+=("--skip-proxy") ;;
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
    local POSTGRES_PASSWORD POSTGRES_SSL JWT_SECRET COOKIE_SECRET
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
    echo "  --- Secrets ---"
    if confirm "Auto-generate JWT_SECRET and COOKIE_SECRET with openssl?" "y"; then
        JWT_SECRET="$(openssl rand -base64 32)"
        COOKIE_SECRET="$(openssl rand -base64 32)"
        echo "  Generated JWT_SECRET and COOKIE_SECRET (32 bytes each)."
    else
        ask_secret JWT_SECRET    "JWT secret (min 32 chars)"    32
        ask_secret COOKIE_SECRET "Cookie secret (min 32 chars)" 32
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
# SECRETS_ENCRYPTION_KEY=   # required only if AI tagging / face recognition is enabled
# OTEL_ENABLED=false
EOF
    umask 022
    chmod 600 "${ENV_FILE}"

    echo
    log "Wrote ${ENV_FILE} (chmod 600). Summary (secrets masked):"
    echo "    APP_URL=${APP_URL}"
    echo "    POSTGRES_HOST=${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB} (user=${POSTGRES_USER}, ssl=${POSTGRES_SSL})"
    echo "    POSTGRES_PASSWORD=********"
    echo "    JWT_SECRET=********  COOKIE_SECRET=********"
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
    local jwt cookie bucket region endpoint akid asecret admin
    pg_host=$(read_env POSTGRES_HOST)
    pg_port=$(read_env POSTGRES_PORT)
    pg_db=$(read_env POSTGRES_DB)
    pg_user=$(read_env POSTGRES_USER)
    pg_pass=$(read_env POSTGRES_PASSWORD)
    pg_ssl=$(read_env POSTGRES_SSL)
    jwt=$(read_env JWT_SECRET)
    cookie=$(read_env COOKIE_SECRET)
    bucket=$(read_env S3_BUCKET)
    region=$(read_env S3_REGION)
    endpoint=$(read_env S3_ENDPOINT)
    akid=$(read_env AWS_ACCESS_KEY_ID)
    asecret=$(read_env AWS_SECRET_ACCESS_KEY)
    admin=$(read_env INITIAL_ADMIN_EMAIL)

    # --- Secret strength ---
    if [ "${#jwt}" -ge 32 ]; then pass "JWT_SECRET length OK"; else warn "JWT_SECRET is shorter than 32 chars"; fi
    if [ "${#cookie}" -ge 32 ]; then pass "COOKIE_SECRET length OK"; else warn "COOKIE_SECRET is shorter than 32 chars"; fi

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
#   nginx  internal reverse proxy, binds 127.0.0.1:${HOST_PORT} (the VPS proxy routes here)
#   api    NestJS + Fastify backend (connects to PostgreSQL over SSL via .env)
#   web    React frontend, static build served by nginx on :80
# CompreFace face-detection is intentionally omitted; it is opt-in later.
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
log "[5/7] Building images..."
cd "${MEMORIAHUB_DIR}"
docker compose build
log "  Images built."

log ""
log "  Running database migrations..."
# prisma-env.js (apps/api/scripts/) builds DATABASE_URL from the POSTGRES_* vars
# in .env (including sslmode=require when POSTGRES_SSL=true), so we just call the
# package script — no manual connection string needed.
docker compose run --rm -T api npm run prisma:migrate
log "  Migrations complete."

log "  Running database seed (roles, permissions, initial admin)..."
docker compose run --rm -T api npm run prisma:seed
log "  Seed complete."

# --- Step 6: start services ---
log ""
log "[6/7] Starting all services..."
docker compose up -d
log "  All containers started."

log "  Waiting for API to initialize..."
API_READY=false
for _ in $(seq 1 60); do
    if docker exec memoriahub-api wget -qO- http://localhost:3000/api/health/live >/dev/null 2>&1; then
        API_READY=true
        break
    fi
    sleep 2
done
if [ "${API_READY}" = "false" ]; then
    log "  WARNING: API health check did not pass within 120 seconds."
    log "  Check logs: docker compose -f ${COMPOSE_FILE} logs api"
fi

# --- Step 7: verify health ---
log ""
log "[7/7] Verifying services..."
sleep 3
RUNNING=$(docker compose ps --format '{{.Name}}' 2>/dev/null | wc -l)
log "  Containers running: ${RUNNING}"
API_STATUS=$(docker exec memoriahub-api wget -qO- http://localhost:3000/api/health/live 2>/dev/null || echo "FAIL")
if echo "${API_STATUS}" | grep -qi "ok\|status\|healthy"; then
    log "  API health:    OK"
else
    log "  API health:    WARN (response: ${API_STATUS})"
    log "                 Check: docker compose -f ${COMPOSE_FILE} logs api"
fi

log ""
log "============================================"
log " MemoriaHub installation complete!"
log "============================================"
log ""
log " Internal URL: http://127.0.0.1:${HOST_PORT}"
log " External URL: https://${DOMAIN}"
log ""
log " If this is the FIRST install, complete these steps:"
log ""
log "   1. Copy the proxy config to the VPS reverse proxy:"
log "      cp ${MEMORIAHUB_DIR}/memoriahub.conf /opt/infra/proxy/nginx/conf.d/"
log ""
log "   2. Issue the TLS certificate:"
log "      certbot certonly --webroot -w /opt/infra/proxy/webroot \\"
log "        -d ${DOMAIN} --config-dir /opt/infra/proxy/letsencrypt"
log ""
log "   3. Reload the VPS proxy:"
log "      docker exec proxy-nginx nginx -t"
log "      docker exec proxy-nginx nginx -s reload"
log ""
log "   4. Register the Google OAuth redirect URI:"
log "      https://${DOMAIN}/api/auth/google/callback"
log ""
log "   5. Verify:"
log "      curl https://${DOMAIN}/api/health/live"
log ""
log " To update later, just run ./install-memoriahub.sh again (it auto-detects"
log " UPDATE mode) or ./update.sh directly."
log "============================================"

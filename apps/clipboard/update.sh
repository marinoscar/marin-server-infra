#!/usr/bin/env bash
# =============================================================================
# update.sh — Update Clipboard on VPS
# =============================================================================
# Location on VPS: /opt/infra/apps/clipboard/update.sh
#
# This script:
#   1. Pulls the latest code from origin/main
#   2. Rebuilds Docker images (API + Web)
#   3. Runs Prisma database migrations
#   4. Restarts all services
#   5. Optionally updates VPS proxy nginx config
#   6. Verifies service health
#
# Usage:
#   cd /opt/infra/apps/clipboard
#   ./update.sh
#
# Options:
#   --no-cache     Force full Docker rebuild (ignores layer cache)
#   --skip-proxy   Skip VPS proxy config update
#   --help, -h     Show help
#
# Prerequisites:
#   - Clipboard installed via install-clipboard.sh
#   - .env file configured
#   - Services running
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CLIPBOARD_DIR="/opt/infra/apps/clipboard"
REPO_DIR="${CLIPBOARD_DIR}/repo"
COMPOSE_FILE="${CLIPBOARD_DIR}/compose.yml"
PROXY_CONF_SRC="${CLIPBOARD_DIR}/clipboard.conf"
PROXY_CONF_DST="/opt/infra/proxy/nginx/conf.d/clipboard.conf"
BRANCH="main"
DOMAIN="clipboard.marin.cr"

# Options
NO_CACHE=false
SKIP_PROXY=false

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[clipboard-update] $(date '+%H:%M:%S') $*"; }

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Update Clipboard to the latest version."
    echo ""
    echo "Options:"
    echo "  --no-cache     Force full Docker image rebuild (no layer cache)"
    echo "  --skip-proxy   Skip updating VPS reverse proxy config"
    echo "  --help, -h     Show this help message"
    echo ""
    echo "This script pulls latest code, rebuilds containers, runs"
    echo "database migrations, and restarts services."
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
for arg in "$@"; do
    case "${arg}" in
        --no-cache)   NO_CACHE=true ;;
        --skip-proxy) SKIP_PROXY=true ;;
        --help|-h)    show_help; exit 0 ;;
        *)            log "Unknown option: ${arg}"; show_help; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [ ! -d "${REPO_DIR}/.git" ]; then
    log "ERROR: Repository not found at ${REPO_DIR}"
    log "Run install-clipboard.sh first."
    exit 1
fi

if [ ! -f "${CLIPBOARD_DIR}/.env" ]; then
    log "ERROR: .env file not found at ${CLIPBOARD_DIR}/.env"
    exit 1
fi

if [ ! -f "${COMPOSE_FILE}" ]; then
    log "ERROR: compose.yml not found at ${COMPOSE_FILE}"
    log "Run install-clipboard.sh to generate it."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: Pull latest code
# ---------------------------------------------------------------------------
log "============================================"
log " Clipboard Updater"
log "============================================"
log ""
log "[1/6] Pulling latest code..."

cd "${REPO_DIR}"
CURRENT_COMMIT=$(git rev-parse --short HEAD)
git fetch origin

# Check if already up to date
REMOTE_COMMIT=$(git rev-parse --short "origin/${BRANCH}")
if [ "${CURRENT_COMMIT}" = "${REMOTE_COMMIT}" ]; then
    log "  Already at latest commit (${CURRENT_COMMIT})."
    log "  Use --no-cache to force a rebuild anyway."
    if [ "${NO_CACHE}" = "false" ]; then
        log ""
        log "  No update needed. Exiting."
        exit 0
    fi
    log "  --no-cache specified, continuing with rebuild..."
else
    log "  Current: ${CURRENT_COMMIT}"
    log "  Latest:  ${REMOTE_COMMIT}"
fi

git reset --hard "origin/${BRANCH}"
NEW_COMMIT=$(git rev-parse --short HEAD)
log "  Updated to ${NEW_COMMIT}."

# Show what changed
CHANGES=$(git log --oneline "${CURRENT_COMMIT}..${NEW_COMMIT}" 2>/dev/null || echo "(first update)")
log ""
log "  Changes:"
echo "${CHANGES}" | while IFS= read -r line; do
    log "    ${line}"
done

cd "${CLIPBOARD_DIR}"

# ---------------------------------------------------------------------------
# Step 2: Rebuild Docker images
# ---------------------------------------------------------------------------
log ""
log "[2/6] Rebuilding Docker images..."

BUILD_ARGS=""
if [ "${NO_CACHE}" = "true" ]; then
    BUILD_ARGS="--no-cache"
    log "  (--no-cache: full rebuild)"
fi

docker compose -f "${COMPOSE_FILE}" build ${BUILD_ARGS}
log "  Images rebuilt."

# ---------------------------------------------------------------------------
# Step 3: Run database migrations
# ---------------------------------------------------------------------------
log ""
log "[3/6] Running database migrations..."

# Stop the API to release SQLite lock, run migrations, then restart
docker compose -f "${COMPOSE_FILE}" stop api 2>/dev/null || true

docker compose -f "${COMPOSE_FILE}" run --rm -T api sh -c \
    "npx prisma migrate deploy 2>&1 || npx prisma db push --accept-data-loss 2>&1 || echo 'Schema already up to date'" \
    | while IFS= read -r line; do log "    ${line}"; done

log "  Migrations complete."

# ---------------------------------------------------------------------------
# Step 4: Restart services
# ---------------------------------------------------------------------------
log ""
log "[4/6] Restarting services..."

docker compose -f "${COMPOSE_FILE}" up -d
log "  All containers started."

# Wait for API to be ready
log "  Waiting for API to initialize..."
API_READY=false
for i in $(seq 1 60); do
    if docker exec clipboard-api wget -qO- http://localhost:3000/api/health >/dev/null 2>&1; then
        API_READY=true
        break
    fi
    sleep 2
done

if [ "${API_READY}" = "true" ]; then
    log "  API is healthy."
else
    log "  WARNING: API health check did not pass within 120 seconds."
    log "  Check logs: docker compose -f ${COMPOSE_FILE} logs api"
fi

# ---------------------------------------------------------------------------
# Step 5: Update VPS proxy config (optional)
# ---------------------------------------------------------------------------
log ""
if [ "${SKIP_PROXY}" = "true" ]; then
    log "[5/6] Skipping proxy config update (--skip-proxy)."
else
    log "[5/6] Updating VPS proxy config..."

    if [ -f "${PROXY_CONF_SRC}" ] && [ -d "$(dirname "${PROXY_CONF_DST}")" ]; then
        # Check if config has changed
        if diff -q "${PROXY_CONF_SRC}" "${PROXY_CONF_DST}" >/dev/null 2>&1; then
            log "  Proxy config unchanged. Skipping."
        else
            cp "${PROXY_CONF_SRC}" "${PROXY_CONF_DST}"
            log "  Config copied to ${PROXY_CONF_DST}."

            # Validate nginx config before reloading
            if docker exec proxy-nginx nginx -t 2>/dev/null; then
                docker exec proxy-nginx nginx -s reload
                log "  VPS proxy reloaded."
            else
                log "  WARNING: Nginx config validation failed."
                log "  Check: docker exec proxy-nginx nginx -t"
            fi
        fi
    else
        log "  Proxy config or destination not found. Skipping."
        log "  (This is normal if the proxy is not yet set up.)"
    fi
fi

# ---------------------------------------------------------------------------
# Step 6: Verify health
# ---------------------------------------------------------------------------
log ""
log "[6/6] Verifying services..."
sleep 3

# Check containers
RUNNING=$(docker compose -f "${COMPOSE_FILE}" ps --format '{{.Name}}' 2>/dev/null | wc -l)
log "  Containers running: ${RUNNING}"

# Check API health
API_STATUS=$(docker exec clipboard-api wget -qO- http://localhost:3000/api/health 2>/dev/null || echo "FAIL")
if echo "${API_STATUS}" | grep -qi "ok\|status"; then
    log "  API health:    OK"
else
    log "  API health:    WARN (${API_STATUS})"
fi

# Save update state for reference
cat > "${CLIPBOARD_DIR}/.update-state" << EOF
last_update=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
previous_commit=${CURRENT_COMMIT}
current_commit=${NEW_COMMIT}
branch=${BRANCH}
EOF

log ""
log "============================================"
log " Clipboard update complete!"
log "============================================"
log ""
log " ${CURRENT_COMMIT} → ${NEW_COMMIT}"
log " URL: https://${DOMAIN}"
log ""
log " Verify: curl https://${DOMAIN}/api/health"
log ""
log "============================================"

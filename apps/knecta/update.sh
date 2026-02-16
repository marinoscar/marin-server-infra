#!/usr/bin/env bash
# =============================================================================
# update.sh - Update Knecta on VPS to the latest version
# =============================================================================
# Location on VPS: /opt/infra/apps/knecta/update.sh
#
# This script updates a running Knecta installation:
#   1. Pulls latest code from origin/main
#   2. Rebuilds Docker images
#   3. Runs database migrations (Prisma)
#   4. Restarts all services (zero-downtime for dependencies)
#   5. Updates VPS proxy config if changed
#   6. Verifies service health
#
# Usage:
#   cd /opt/infra/apps/knecta
#   ./update.sh              # Standard update
#   ./update.sh --no-cache   # Force full rebuild (slower, use if layers are stale)
#   ./update.sh --skip-proxy # Skip proxy config update
#
# Prerequisites:
#   - Knecta already installed via install-knecta.sh
#   - .env file configured
#   - Services currently running
#
# For first-time installation, use install-knecta.sh instead.
# =============================================================================
set -euo pipefail

KNECTA_DIR="/opt/infra/apps/knecta"
REPO_DIR="${KNECTA_DIR}/repo"
BRANCH="main"
PROXY_CONF_DIR="/opt/infra/proxy/nginx/conf.d"
BUILD_FLAGS=""
SKIP_PROXY=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --no-cache)
            BUILD_FLAGS="--no-cache"
            ;;
        --skip-proxy)
            SKIP_PROXY=true
            ;;
        --help|-h)
            echo "Usage: ./update.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --no-cache     Force full Docker rebuild (no layer cache)"
            echo "  --skip-proxy   Skip VPS proxy config update"
            echo "  --help, -h     Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run ./update.sh --help for usage"
            exit 1
            ;;
    esac
done

log() { echo "[knecta] $*"; }

# =============================================================================
# Pre-flight checks
# =============================================================================
log "============================================"
log " Knecta Updater"
log "============================================"
log ""

# Check we're in the right directory
if [ ! -f "${KNECTA_DIR}/compose.yml" ]; then
    log "ERROR: compose.yml not found at ${KNECTA_DIR}/compose.yml"
    log "Are you running from the correct directory?"
    log "Expected: ${KNECTA_DIR}"
    exit 1
fi

# Check repo exists
if [ ! -d "${REPO_DIR}/.git" ]; then
    log "ERROR: Repository not found at ${REPO_DIR}"
    log "Run install-knecta.sh first for initial setup."
    exit 1
fi

# Check .env exists
if [ ! -f "${KNECTA_DIR}/.env" ]; then
    log "ERROR: .env file not found."
    log "Run install-knecta.sh first for initial setup."
    exit 1
fi

# Load env vars needed by this script
set -a
# shellcheck disable=SC1091
source "${KNECTA_DIR}/.env"
set +a

# Capture current commit for rollback info
CURRENT_COMMIT=$(cd "${REPO_DIR}" && git rev-parse --short HEAD)
log "Current version: ${CURRENT_COMMIT}"

# -----------------------------------------------
# Step 1: Pull latest code
# -----------------------------------------------
log ""
log "[1/6] Pulling latest code from origin/${BRANCH}..."
cd "${REPO_DIR}"
git fetch origin

# Check if there are actually new commits
LOCAL_HEAD=$(git rev-parse HEAD)
REMOTE_HEAD=$(git rev-parse "origin/${BRANCH}")

if [ "${LOCAL_HEAD}" = "${REMOTE_HEAD}" ]; then
    log "  Already up to date (${CURRENT_COMMIT}). Nothing to do."
    log ""
    log "  To force a rebuild anyway, run:"
    log "    docker compose build --no-cache && docker compose up -d"
    exit 0
fi

NEW_COMMIT=$(git rev-parse --short "origin/${BRANCH}")
COMMIT_COUNT=$(git rev-list HEAD.."origin/${BRANCH}" --count)
log "  ${COMMIT_COUNT} new commit(s): ${CURRENT_COMMIT} -> ${NEW_COMMIT}"

# Show what changed (summary)
log ""
log "  Changes:"
git log --oneline HEAD.."origin/${BRANCH}" | while read -r line; do
    log "    ${line}"
done

# Apply changes
git reset --hard "origin/${BRANCH}"
cd "${KNECTA_DIR}"
log ""
log "  Code updated to ${NEW_COMMIT}."

# -----------------------------------------------
# Step 2: Rebuild Docker images
# -----------------------------------------------
log ""
log "[2/6] Rebuilding Docker images..."
cd "${KNECTA_DIR}"
# shellcheck disable=SC2086
docker compose build ${BUILD_FLAGS}
log "  Images rebuilt."

# -----------------------------------------------
# Step 3: Run database migrations
# -----------------------------------------------
log ""
log "[3/6] Running database migrations..."

# Use a temporary container to run migrations (API not restarted yet)
docker compose run --rm -T api npm run prisma:migrate 2>&1 | while read -r line; do
    log "  ${line}"
done
log "  Migrations complete."

# -----------------------------------------------
# Step 4: Restart services
# -----------------------------------------------
log ""
log "[4/6] Restarting services..."

# Recreate only containers whose images changed
# Dependencies (neo4j, sandbox) only restart if their config changed
docker compose up -d
log "  Services restarted."

# Wait for API to be ready
log "  Waiting for API to initialize..."
API_READY=false
for i in $(seq 1 60); do
    if docker compose exec -T api wget -qO- http://localhost:3000/api/health/live >/dev/null 2>&1; then
        API_READY=true
        break
    fi
    sleep 2
done

if [ "${API_READY}" = "false" ]; then
    log "  WARNING: API health check did not pass within 120 seconds."
    log "  Check logs: docker compose logs api"
    log ""
    log "  To rollback: git -C ${REPO_DIR} reset --hard ${CURRENT_COMMIT}"
    log "               docker compose build && docker compose up -d"
fi

# -----------------------------------------------
# Step 5: Update VPS proxy config (if changed)
# -----------------------------------------------
log ""
log "[5/6] Checking proxy configuration..."

if [ "${SKIP_PROXY}" = "true" ]; then
    log "  Skipped (--skip-proxy flag)."
elif [ ! -d "${PROXY_CONF_DIR}" ]; then
    log "  Proxy config directory not found at ${PROXY_CONF_DIR}."
    log "  Skipping proxy update. Update manually if needed."
else
    SOURCE_CONF="${KNECTA_DIR}/knecta.conf"
    DEST_CONF="${PROXY_CONF_DIR}/knecta.conf"

    if [ ! -f "${SOURCE_CONF}" ]; then
        log "  No knecta.conf in deploy directory. Skipping."
    elif [ ! -f "${DEST_CONF}" ]; then
        log "  Proxy config not yet deployed. Copying..."
        cp "${SOURCE_CONF}" "${DEST_CONF}"
        log "  Reloading proxy..."
        docker exec proxy-nginx nginx -t 2>&1 && docker exec proxy-nginx nginx -s reload
        log "  Proxy updated."
    elif ! diff -q "${SOURCE_CONF}" "${DEST_CONF}" >/dev/null 2>&1; then
        log "  Proxy config changed. Updating..."
        cp "${SOURCE_CONF}" "${DEST_CONF}"
        log "  Testing nginx config..."
        if docker exec proxy-nginx nginx -t 2>&1; then
            docker exec proxy-nginx nginx -s reload
            log "  Proxy reloaded."
        else
            log "  WARNING: nginx config test failed! Restoring previous config."
            log "  Check the knecta.conf for errors."
        fi
    else
        log "  Proxy config unchanged. No reload needed."
    fi
fi

# -----------------------------------------------
# Step 6: Verify health
# -----------------------------------------------
log ""
log "[6/6] Verifying services..."
sleep 3

# Check containers
RUNNING=$(docker compose ps --format '{{.Name}}' 2>/dev/null | wc -l)
log "  Containers running: ${RUNNING}"

# Check API health (detailed)
API_STATUS=$(docker compose exec -T api wget -qO- http://localhost:3000/api/health/ready 2>/dev/null || echo "FAIL")
if echo "${API_STATUS}" | grep -qi "ok\|up\|status"; then
    log "  API health:    OK"
else
    log "  API health:    WARN (response: ${API_STATUS})"
    log "                 Check: docker compose logs api"
fi

# Check web
WEB_STATUS=$(docker compose exec -T web wget -qO- http://localhost:80/ 2>/dev/null && echo "OK" || echo "FAIL")
if [ "${WEB_STATUS}" != "FAIL" ]; then
    log "  Web health:    OK"
else
    log "  Web health:    WARN"
    log "                 Check: docker compose logs web"
fi

# Summary
log ""
log "============================================"
log " Update complete!"
log "============================================"
log ""
log " Version:  ${CURRENT_COMMIT} -> ${NEW_COMMIT}"
log " Commits:  ${COMMIT_COUNT}"
log " URL:      https://knecta.marin.cr"
log ""
log " If something went wrong, rollback with:"
log "   cd ${KNECTA_DIR}"
log "   git -C repo reset --hard ${CURRENT_COMMIT}"
log "   docker compose build && docker compose up -d"
log ""
log "============================================"

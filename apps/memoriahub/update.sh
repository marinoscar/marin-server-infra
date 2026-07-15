#!/usr/bin/env bash
# =============================================================================
# update.sh — Update MemoriaHub on the VPS
# =============================================================================
# Location on VPS: /opt/infra/apps/memoriahub/update.sh
#
# This script (the UPDATE path; install-memoriahub.sh delegates here when an
# install already exists):
#   1. Pulls the latest code from origin/main
#   2. Rebuilds the Docker images (api + web)
#   3. Runs Prisma migrations (deploy only — additive, NO seed)
#   4. Restarts all services
#   5. Optionally updates the VPS proxy nginx config (validated reload)
#   6. Verifies service health
#
# It is idempotent: with no upstream changes and without --no-cache it exits
# early without rebuilding. Output is teed to a timestamped log under ./logs
# (only the 10 newest are kept) and the commit transition is recorded in
# .update-state.
#
# Usage:
#   cd /opt/infra/apps/memoriahub
#   ./update.sh
#
# Options:
#   --no-cache     Force a full Docker rebuild (ignore layer cache; also bypasses
#                  the "already up to date" early exit)
#   --skip-proxy   Skip copying/reloading the VPS proxy config
#   --help, -h     Show this help
#
# Prerequisites:
#   - MemoriaHub installed via install-memoriahub.sh (.env + compose.yml present)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
MEMORIAHUB_DIR="/opt/infra/apps/memoriahub"
REPO_DIR="${MEMORIAHUB_DIR}/repo"
COMPOSE_FILE="${MEMORIAHUB_DIR}/compose.yml"
PROXY_CONF_SRC="${MEMORIAHUB_DIR}/memoriahub.conf"
PROXY_CONF_DST="/opt/infra/proxy/nginx/conf.d/memoriahub.conf"
BRANCH="main"
DOMAIN="memoriahub.marin.cr"

# The production image (apps/api/Dockerfile) does NOT copy prisma.config.ts, but
# Prisma 7 reads the datasource url from it. The running app sets DATABASE_URL
# programmatically so it is unaffected, but the migrate CLI needs the config —
# so we bind-mount it for the one-off `compose run` below.
PRISMA_CONFIG_SRC="${REPO_DIR}/apps/api/prisma.config.ts"

# Options
NO_CACHE=false
SKIP_PROXY=false

# ---------------------------------------------------------------------------
# Logging — output goes to both terminal and a timestamped log file
# ---------------------------------------------------------------------------
LOG_DIR="${MEMORIAHUB_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/update-$(date '+%Y%m%d-%H%M%S').log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# Keep only the last 10 log files
ls -1t "${LOG_DIR}"/update-*.log 2>/dev/null | tail -n +11 | xargs -r rm -f

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[memoriahub-update] $(date '+%H:%M:%S') $*"; }

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Update MemoriaHub to the latest version."
    echo ""
    echo "Options:"
    echo "  --no-cache     Force full Docker image rebuild (no layer cache)"
    echo "  --skip-proxy   Skip updating the VPS reverse proxy config"
    echo "  --help, -h     Show this help message"
    echo ""
    echo "Pulls latest code, rebuilds containers, runs database migrations"
    echo "(deploy only — no seed), and restarts services."
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
    log "Run install-memoriahub.sh first."
    exit 1
fi

if [ ! -f "${MEMORIAHUB_DIR}/.env" ]; then
    log "ERROR: .env file not found at ${MEMORIAHUB_DIR}/.env"
    exit 1
fi

if [ ! -f "${COMPOSE_FILE}" ]; then
    log "ERROR: compose.yml not found at ${COMPOSE_FILE}"
    log "Run install-memoriahub.sh to generate it."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: Pull latest code
# ---------------------------------------------------------------------------
log "============================================"
log " MemoriaHub Updater"
log "============================================"
log ""
log "[1/6] Pulling latest code..."

cd "${REPO_DIR}"
CURRENT_COMMIT=$(git rev-parse --short HEAD)
git fetch origin

REMOTE_COMMIT=$(git rev-parse --short "origin/${BRANCH}")
if [ "${CURRENT_COMMIT}" = "${REMOTE_COMMIT}" ]; then
    log "  Already at latest commit (${CURRENT_COMMIT})."
    if [ "${NO_CACHE}" = "false" ]; then
        log ""
        log "  No update needed. Exiting (use --no-cache to force a rebuild)."
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

CHANGES=$(git log --oneline "${CURRENT_COMMIT}..${NEW_COMMIT}" 2>/dev/null || echo "(first update)")
log ""
log "  Changes:"
echo "${CHANGES}" | while IFS= read -r line; do log "    ${line}"; done

cd "${MEMORIAHUB_DIR}"

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

# Stamp the built images with the deployed git commit + build time as OCI image
# labels (org.opencontainers.image.revision/.created), consumed by compose.yml's
# build.labels. This is what lets verify-deployment.sh and `docker inspect` report
# exactly which commit a running container was built from — see verify-deployment.sh.
export GIT_SHA="$(git -C "${REPO_DIR}" rev-parse --short HEAD)"
export BUILD_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
log "  Stamping images: revision=${GIT_SHA} created=${BUILD_TIME}"

docker compose -f "${COMPOSE_FILE}" build ${BUILD_ARGS}
log "  Images rebuilt."

# ---------------------------------------------------------------------------
# Step 3: Run database migrations (deploy only — no seed)
# ---------------------------------------------------------------------------
log ""
log "[3/6] Running database migrations..."

# Stop the API to run migrations cleanly, then restart.
docker compose -f "${COMPOSE_FILE}" stop api 2>/dev/null || true

# prisma-env.js builds DATABASE_URL from the POSTGRES_* vars in .env (the api
# service has env_file: .env). We also bind-mount prisma.config.ts (which the
# production image omits) so the Prisma 7 CLI can read the datasource url.
PRISMA_MOUNT=()
if [ -f "${PRISMA_CONFIG_SRC}" ]; then
    PRISMA_MOUNT=(-v "${PRISMA_CONFIG_SRC}:/app/apps/api/prisma.config.ts:ro")
else
    log "    WARNING: prisma.config.ts not found at ${PRISMA_CONFIG_SRC}; migrate may fail."
fi
docker compose -f "${COMPOSE_FILE}" run --rm -T ${PRISMA_MOUNT[@]+"${PRISMA_MOUNT[@]}"} \
    api npm run prisma:migrate 2>&1 \
    | while IFS= read -r line; do log "    ${line}"; done

# The pipe above masks the migrate exit code from `set -e`; check it explicitly so
# a failed migration aborts the update instead of restarting on a stale schema.
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    log "  ERROR: database migrations FAILED. Aborting update."
    log "  Restarting the previous API container (old image, matches the un-migrated"
    log "  DB) to avoid downtime, then exiting. Fix the issue and re-run ./update.sh."
    docker compose -f "${COMPOSE_FILE}" start api >/dev/null 2>&1 || true
    exit 1
fi

log "  Migrations complete."

# ---------------------------------------------------------------------------
# Step 4: Restart services
# ---------------------------------------------------------------------------
log ""
log "[4/6] Restarting services..."

docker compose -f "${COMPOSE_FILE}" up -d
log "  All containers started."

# Restart nginx so it re-resolves the new upstream container IPs.
docker compose -f "${COMPOSE_FILE}" restart nginx 2>/dev/null || true
log "  Nginx restarted."

log "  Waiting for API to initialize..."
API_READY=false
for _ in $(seq 1 60); do
    if docker exec memoriahub-api wget -qO- http://127.0.0.1:3000/api/health/live >/dev/null 2>&1; then
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
        if diff -q "${PROXY_CONF_SRC}" "${PROXY_CONF_DST}" >/dev/null 2>&1; then
            log "  Proxy config unchanged. Skipping."
        else
            cp "${PROXY_CONF_SRC}" "${PROXY_CONF_DST}"
            log "  Config copied to ${PROXY_CONF_DST}."
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
        log "  (Normal if the proxy is not yet set up — see DEPLOY.md.)"
    fi
fi

# ---------------------------------------------------------------------------
# Step 6: Verify health
# ---------------------------------------------------------------------------
log ""
log "[6/6] Verifying services..."
sleep 3

RUNNING=$(docker compose -f "${COMPOSE_FILE}" ps --format '{{.Name}}' 2>/dev/null | wc -l)
log "  Containers running: ${RUNNING}"

API_STATUS=$(docker exec memoriahub-api wget -qO- http://127.0.0.1:3000/api/health/live 2>/dev/null || echo "FAIL")
if echo "${API_STATUS}" | grep -qi "ok\|status\|healthy"; then
    log "  API health:    OK"
else
    log "  API health:    WARN (${API_STATUS})"
fi

# CompreFace sidecar — face-detection backend. The api reaches it by name at
# http://compreface-core:3000 over the shared network. `up -d` above starts it
# only if it is defined in compose.yml; a compose.yml generated before the
# sidecar was added will not have it, so guide the operator to regenerate.
if docker compose -f "${COMPOSE_FILE}" config --services 2>/dev/null | grep -qx "compreface-core"; then
    if docker exec memoriahub-api wget -qO- http://compreface-core:3000/status 2>/dev/null | grep -qi '"status":"ok"'; then
        log "  CompreFace:    OK"
    else
        log "  CompreFace:    WARN — not reachable yet (it loads models on boot)."
        log "                 Check: docker compose -f ${COMPOSE_FILE} logs compreface-core"
    fi
else
    log "  CompreFace:    MISSING from compose.yml — face detection will not work."
    log "                 Regenerate it: ./install-memoriahub.sh --reinstall"
fi

# Save update state for reference
cat > "${MEMORIAHUB_DIR}/.update-state" << EOF
last_update=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
previous_commit=${CURRENT_COMMIT}
current_commit=${NEW_COMMIT}
branch=${BRANCH}
EOF

log ""
log "============================================"
log " MemoriaHub update complete!"
log "============================================"
log ""
log " ${CURRENT_COMMIT} -> ${NEW_COMMIT}"
log " URL: https://${DOMAIN}"
log ""
log " Verify: curl https://${DOMAIN}/api/health/live"
log ""
log "============================================"

#!/usr/bin/env bash
# =============================================================================
# install-knecta.sh - Install or update Knecta on VPS
# =============================================================================
# Location on VPS: /opt/infra/apps/knecta/install-knecta.sh
#
# This script:
#   1. Creates data directories for persistent volumes
#   2. Clones (or pulls) the Knecta repository
#   3. Validates that .env exists
#   4. Builds images and starts dependencies (Neo4j, sandbox)
#   5. Runs Prisma migrations and database seed (against cloud PostgreSQL)
#   6. Starts all services (API, web)
#   7. Verifies service health
#
# Usage:
#   cd /opt/infra/apps/knecta
#   chmod +x install-knecta.sh
#   ./install-knecta.sh
#
# For updates, just run the script again. It pulls latest code,
# rebuilds images, and runs any new migrations.
# =============================================================================
set -euo pipefail

KNECTA_DIR="/opt/infra/apps/knecta"
REPO_DIR="${KNECTA_DIR}/repo"
REPO_URL="https://github.com/marinoscar/Knecta.git"
BRANCH="main"

log() { echo "[knecta] $*"; }

# -----------------------------------------------
# Step 1: Create directory structure
# -----------------------------------------------
log "============================================"
log " Knecta Installer"
log "============================================"
log ""
log "[1/7] Setting up directories..."
mkdir -p "${KNECTA_DIR}/data/neo4j"
log "  Directories ready."

# -----------------------------------------------
# Step 2: Clone or pull the repository
# -----------------------------------------------
log ""
log "[2/7] Fetching source code..."
if [ -d "${REPO_DIR}/.git" ]; then
    log "  Repository exists. Pulling latest from ${BRANCH}..."
    cd "${REPO_DIR}"
    git fetch origin
    git reset --hard "origin/${BRANCH}"
    cd "${KNECTA_DIR}"
    log "  Updated to latest."
else
    log "  Cloning from ${REPO_URL}..."
    git clone --branch "${BRANCH}" "${REPO_URL}" "${REPO_DIR}"
    log "  Clone complete."
fi

# -----------------------------------------------
# Step 3: Check .env exists
# -----------------------------------------------
log ""
log "[3/7] Checking environment file..."
if [ ! -f "${KNECTA_DIR}/.env" ]; then
    log ""
    log "  ERROR: .env file not found at ${KNECTA_DIR}/.env"
    log ""
    log "  Create it from the template:"
    log "    cp ${KNECTA_DIR}/.env.example ${KNECTA_DIR}/.env"
    log "    nano ${KNECTA_DIR}/.env"
    log ""
    log "  Then run this script again."
    exit 1
fi
log "  .env file found."

# Load variables needed by this script (NEO4J_USER, NEO4J_PASSWORD)
set -a
# shellcheck disable=SC1091
source "${KNECTA_DIR}/.env"
set +a

# -----------------------------------------------
# Step 4: Build images and start dependencies
# -----------------------------------------------
log ""
log "[4/7] Building images and starting dependencies..."
cd "${KNECTA_DIR}"
docker compose build
docker compose up -d neo4j sandbox
log "  Waiting for Neo4j and sandbox to be healthy..."

# Wait for Neo4j health check
NEO4J_READY=false
for i in $(seq 1 60); do
    if docker compose exec -T neo4j cypher-shell -u "${NEO4J_USER:-neo4j}" -p "${NEO4J_PASSWORD}" 'RETURN 1' >/dev/null 2>&1; then
        NEO4J_READY=true
        break
    fi
    sleep 2
done

if [ "${NEO4J_READY}" = "false" ]; then
    log "  ERROR: Neo4j did not become healthy within 120 seconds."
    log "  Check logs: docker compose logs neo4j"
    exit 1
fi
log "  Dependencies ready."

# -----------------------------------------------
# Step 5: Run Prisma migrations + seed
# -----------------------------------------------
log ""
log "[5/7] Running database migrations (against cloud PostgreSQL)..."
docker compose run --rm -T api npm run prisma:migrate
log "  Migrations complete."

log "  Running database seed..."
docker compose run --rm -T api npm run prisma:seed
log "  Seed complete."

# -----------------------------------------------
# Step 6: Start all services
# -----------------------------------------------
log ""
log "[6/7] Starting all services..."
docker compose up -d
log "  All containers started."

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
fi

# -----------------------------------------------
# Step 7: Verify health
# -----------------------------------------------
log ""
log "[7/7] Verifying services..."
sleep 3

# Check containers are running
RUNNING=$(docker compose ps --format '{{.Name}}' 2>/dev/null | wc -l)
log "  Containers running: ${RUNNING}"

# Check API health
API_STATUS=$(docker compose exec -T api wget -qO- http://localhost:3000/api/health/live 2>/dev/null || echo "FAIL")
if echo "${API_STATUS}" | grep -qi "ok\|up\|live\|status"; then
    log "  API health:    OK"
else
    log "  API health:    WARN (response: ${API_STATUS})"
    log "                 Check: docker compose logs api"
fi

log ""
log "============================================"
log " Knecta installation complete!"
log "============================================"
log ""
log " External URL: https://knecta.marin.cr"
log ""
log " If this is the first install, complete these steps:"
log ""
log "   1. Copy proxy config to the VPS reverse proxy:"
log "      cp ${KNECTA_DIR}/knecta.conf /opt/infra/proxy/nginx/conf.d/"
log ""
log "   2. Issue TLS certificate:"
log "      certbot certonly --webroot -w /opt/infra/proxy/webroot -d knecta.marin.cr"
log ""
log "   3. Reload the VPS proxy:"
log "      docker exec proxy-nginx nginx -t"
log "      docker exec proxy-nginx nginx -s reload"
log ""
log "   4. Configure Google OAuth redirect URI:"
log "      https://knecta.marin.cr/api/auth/google/callback"
log ""
log "   5. Verify:"
log "      curl https://knecta.marin.cr/api/health/live"
log ""
log "============================================"

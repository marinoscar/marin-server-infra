#!/usr/bin/env bash
# =============================================================================
# rollback.sh - Rollback Knecta to a previous version
# =============================================================================
# Location on VPS: /opt/infra/apps/knecta/rollback.sh
#
# This script rolls back a Knecta installation:
#   1. Detects which migrations need reverting
#   2. Generates rollback SQL via prisma migrate diff
#   3. Executes rollback SQL and cleans migration records
#   4. Resets code to target commit
#   5. Rebuilds Docker images
#   6. Restarts all services
#   7. Updates VPS proxy config if changed
#   8. Verifies service health
#
# Usage:
#   cd /opt/infra/apps/knecta
#   ./rollback.sh                  # Rollback to previous version (from .update-state)
#   ./rollback.sh abc1234          # Rollback to specific commit
#   ./rollback.sh --force abc1234  # Skip confirmation prompts
#   ./rollback.sh --skip-proxy     # Skip proxy config update
#
# Prerequisites:
#   - Knecta already running (installed via install-knecta.sh, updated via update.sh)
#   - .env file configured
#   - Database accessible
#
# WARNING:
#   - Migration rollback may cause DATA LOSS (e.g., dropping columns/tables)
#   - Always review the generated rollback SQL before confirming
#   - Data-only migrations (custom INSERT/UPDATE) cannot be auto-reversed
#   - Consider backing up the database before rolling back
# =============================================================================
set -euo pipefail

KNECTA_DIR="/opt/infra/apps/knecta"
REPO_DIR="${KNECTA_DIR}/repo"
STATE_FILE="${KNECTA_DIR}/.update-state"
PROXY_CONF_DIR="/opt/infra/proxy/nginx/conf.d"
SKIP_PROXY=false
FORCE=false
TARGET_COMMIT=""

# Parse arguments
for arg in "$@"; do
    case $arg in
        --force|-f)
            FORCE=true
            ;;
        --skip-proxy)
            SKIP_PROXY=true
            ;;
        --help|-h)
            echo "Usage: ./rollback.sh [OPTIONS] [COMMIT]"
            echo ""
            echo "Arguments:"
            echo "  COMMIT         Target commit to rollback to (default: previous version from .update-state)"
            echo ""
            echo "Options:"
            echo "  --force, -f    Skip confirmation prompts"
            echo "  --skip-proxy   Skip VPS proxy config update"
            echo "  --help, -h     Show this help message"
            echo ""
            echo "Examples:"
            echo "  ./rollback.sh                  # Rollback to previous version"
            echo "  ./rollback.sh abc1234          # Rollback to specific commit"
            echo "  ./rollback.sh --force          # Rollback without prompts"
            exit 0
            ;;
        -*)
            echo "Unknown option: $arg"
            echo "Run ./rollback.sh --help for usage"
            exit 1
            ;;
        *)
            if [ -n "${TARGET_COMMIT}" ]; then
                echo "ERROR: Multiple commit arguments provided."
                echo "Run ./rollback.sh --help for usage"
                exit 1
            fi
            TARGET_COMMIT="$arg"
            ;;
    esac
done

log() { echo "[knecta] $*"; }

confirm() {
    if [ "${FORCE}" = "true" ]; then
        return 0
    fi
    local prompt="$1"
    read -r -p "[knecta] ${prompt} [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# Pre-flight checks
# =============================================================================
log "============================================"
log " Knecta Rollback"
log "============================================"
log ""

# Check we're in the right directory
if [ ! -f "${KNECTA_DIR}/compose.yml" ]; then
    log "ERROR: compose.yml not found at ${KNECTA_DIR}/compose.yml"
    log "Are you running from the correct directory?"
    exit 1
fi

# Check repo exists
if [ ! -d "${REPO_DIR}/.git" ]; then
    log "ERROR: Repository not found at ${REPO_DIR}"
    exit 1
fi

# Check .env exists
if [ ! -f "${KNECTA_DIR}/.env" ]; then
    log "ERROR: .env file not found."
    exit 1
fi

# Load env vars
set -a
# shellcheck disable=SC1091
source "${KNECTA_DIR}/.env"
set +a

# Determine rollback target
CURRENT_COMMIT=$(cd "${REPO_DIR}" && git rev-parse --short HEAD)

if [ -n "${TARGET_COMMIT}" ]; then
    # Explicit commit provided — verify it exists
    if ! cd "${REPO_DIR}" && git cat-file -t "${TARGET_COMMIT}" >/dev/null 2>&1; then
        log "ERROR: Commit '${TARGET_COMMIT}' not found in repository."
        log "Try: git -C ${REPO_DIR} fetch origin"
        exit 1
    fi
    ROLLBACK_TO=$(cd "${REPO_DIR}" && git rev-parse --short "${TARGET_COMMIT}")
    ROLLBACK_TO_FULL=$(cd "${REPO_DIR}" && git rev-parse "${TARGET_COMMIT}")
elif [ -f "${STATE_FILE}" ]; then
    # Read from update state
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
    ROLLBACK_TO="${FROM_COMMIT}"
    ROLLBACK_TO_FULL="${FROM_COMMIT_FULL}"
    log "Using previous version from .update-state"
    log "  Last update: ${FROM_COMMIT} -> ${TO_COMMIT} (${UPDATE_TIMESTAMP})"
else
    log "ERROR: No target commit specified and no .update-state found."
    log ""
    log "Usage:"
    log "  ./rollback.sh <commit>    # Rollback to specific commit"
    log ""
    log "The .update-state file is created automatically by update.sh."
    exit 1
fi

# Sanity check: don't rollback to the same commit
if [ "${CURRENT_COMMIT}" = "${ROLLBACK_TO}" ]; then
    log "Already at version ${CURRENT_COMMIT}. Nothing to rollback."
    exit 0
fi

log "Current version: ${CURRENT_COMMIT}"
log "Rollback target: ${ROLLBACK_TO}"
log ""

# Show what will be reverted
log "Commits being reverted:"
cd "${REPO_DIR}"
git log --oneline "${ROLLBACK_TO_FULL}..HEAD" | while read -r line; do
    log "  ${line}"
done
log ""

# =============================================================================
# Step 1: Detect migration changes
# =============================================================================
log "[1/7] Detecting migration changes..."

# Get migrations at current commit (filesystem)
CURRENT_MIGRATIONS=$(ls -1 "${REPO_DIR}/apps/api/prisma/migrations/" 2>/dev/null \
    | grep -v migration_lock.toml | sort || true)

# Get migrations at target commit (from git)
TARGET_MIGRATIONS=$(cd "${REPO_DIR}" && git ls-tree --name-only "${ROLLBACK_TO_FULL}" \
    -- apps/api/prisma/migrations/ 2>/dev/null \
    | sed 's|apps/api/prisma/migrations/||' \
    | grep -v migration_lock.toml | sort || true)

# Migrations that need to be rolled back (exist now but not in target)
MIGRATIONS_TO_REMOVE=$(comm -23 <(echo "${CURRENT_MIGRATIONS}") <(echo "${TARGET_MIGRATIONS}") || true)

if [ -z "${MIGRATIONS_TO_REMOVE}" ]; then
    log "  No migrations to rollback."
    NEEDS_MIGRATION_ROLLBACK=false
else
    NEEDS_MIGRATION_ROLLBACK=true
    MIGRATION_COUNT=$(echo "${MIGRATIONS_TO_REMOVE}" | wc -l | tr -d ' ')
    log "  ${MIGRATION_COUNT} migration(s) to rollback:"
    echo "${MIGRATIONS_TO_REMOVE}" | while read -r m; do
        log "    - ${m}"
    done
fi
log ""

# =============================================================================
# Step 2: Generate rollback SQL (if migrations changed)
# =============================================================================
ROLLBACK_SQL="/tmp/knecta-rollback-${CURRENT_COMMIT}-to-${ROLLBACK_TO}.sql"

if [ "${NEEDS_MIGRATION_ROLLBACK}" = "true" ]; then
    log "[2/7] Generating rollback SQL..."

    # Extract target schema from git
    TARGET_SCHEMA="/tmp/knecta-target-schema.prisma"
    cd "${REPO_DIR}"
    git show "${ROLLBACK_TO_FULL}:apps/api/prisma/schema.prisma" > "${TARGET_SCHEMA}"

    # Generate diff SQL using the current API image
    # --from-schema-datamodel: current schema (in the built image)
    # --to-schema-datamodel: target schema (extracted from git, mounted into container)
    cd "${KNECTA_DIR}"
    if docker compose run --rm -T \
        -v "${TARGET_SCHEMA}:/tmp/target-schema.prisma:ro" \
        api npx prisma migrate diff \
        --from-schema-datamodel prisma/schema.prisma \
        --to-schema-datamodel /tmp/target-schema.prisma \
        --script > "${ROLLBACK_SQL}" 2>/dev/null; then

        if [ ! -s "${ROLLBACK_SQL}" ]; then
            log "  No schema differences detected (migrations may be data-only)."
            log "  Migration records will still be cleaned up."
        else
            log "  Rollback SQL generated:"
            log ""
            while IFS= read -r line; do
                log "    ${line}"
            done < "${ROLLBACK_SQL}"
            log ""
        fi
    else
        log "  WARNING: Failed to generate rollback SQL via prisma migrate diff."
        log "  This can happen if the schema change is not diff-compatible."
        log ""
        log "  You may need to manually write the rollback SQL."
        log "  Continuing with code rollback only..."
        NEEDS_MIGRATION_ROLLBACK=false
    fi

    # Clean up temp schema
    rm -f "${TARGET_SCHEMA}"
else
    log "[2/7] No migration rollback needed. Skipping SQL generation."
fi
log ""

# =============================================================================
# Confirmation
# =============================================================================
if [ "${NEEDS_MIGRATION_ROLLBACK}" = "true" ]; then
    log "WARNING: This will execute rollback SQL against the production database."
    log "         Migration rollback may cause DATA LOSS (dropped columns/tables)."
    log "         Consider backing up the database first:"
    log "           docker compose exec -T db pg_dump -U ${POSTGRES_USER} ${POSTGRES_DB} > backup.sql"
    log ""
fi

if ! confirm "Proceed with rollback ${CURRENT_COMMIT} -> ${ROLLBACK_TO}?"; then
    log "Rollback cancelled."
    rm -f "${ROLLBACK_SQL}"
    exit 0
fi

# =============================================================================
# Step 3: Execute migration rollback
# =============================================================================
if [ "${NEEDS_MIGRATION_ROLLBACK}" = "true" ]; then
    log ""
    log "[3/7] Rolling back database migrations..."

    # Execute rollback SQL (if any schema changes)
    if [ -s "${ROLLBACK_SQL}" ]; then
        log "  Executing rollback SQL..."
        if docker compose exec -T db psql \
            -U "${POSTGRES_USER}" \
            -d "${POSTGRES_DB}" \
            -v ON_ERROR_STOP=1 \
            < "${ROLLBACK_SQL}" 2>&1 | while read -r line; do
                log "    ${line}"
            done; then
            log "  Schema changes reverted."
        else
            log "  ERROR: Rollback SQL failed!"
            log "  The database may be in an inconsistent state."
            log "  Review and fix manually, then re-run or continue."
            log ""
            if ! confirm "Continue with code rollback despite SQL failure?"; then
                log "Rollback aborted. Database may need manual intervention."
                rm -f "${ROLLBACK_SQL}"
                exit 1
            fi
        fi
    fi

    # Remove migration records from _prisma_migrations
    log "  Cleaning migration records..."
    echo "${MIGRATIONS_TO_REMOVE}" | while read -r migration_name; do
        if [ -n "${migration_name}" ]; then
            docker compose exec -T db psql \
                -U "${POSTGRES_USER}" \
                -d "${POSTGRES_DB}" \
                -c "DELETE FROM _prisma_migrations WHERE migration_name = '${migration_name}';" \
                >/dev/null 2>&1
            log "    Removed: ${migration_name}"
        fi
    done
    log "  Migration rollback complete."
else
    log ""
    log "[3/7] No migration rollback needed. Skipping."
fi

# Clean up temp SQL
rm -f "${ROLLBACK_SQL}"

# =============================================================================
# Step 4: Reset code to target commit
# =============================================================================
log ""
log "[4/7] Resetting code to ${ROLLBACK_TO}..."
cd "${REPO_DIR}"
git reset --hard "${ROLLBACK_TO_FULL}"
cd "${KNECTA_DIR}"
log "  Code reset to ${ROLLBACK_TO}."

# =============================================================================
# Step 5: Rebuild Docker images
# =============================================================================
log ""
log "[5/7] Rebuilding Docker images..."
cd "${KNECTA_DIR}"
docker compose build
log "  Images rebuilt."

# =============================================================================
# Step 6: Restart services
# =============================================================================
log ""
log "[6/7] Restarting services..."
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
fi

# Update proxy config (same logic as update.sh)
log ""
log "[7/7] Checking proxy configuration..."

if [ "${SKIP_PROXY}" = "true" ]; then
    log "  Skipped (--skip-proxy flag)."
elif [ ! -d "${PROXY_CONF_DIR}" ]; then
    log "  Proxy config directory not found. Skipping."
else
    SOURCE_CONF="${KNECTA_DIR}/knecta.conf"
    DEST_CONF="${PROXY_CONF_DIR}/knecta.conf"

    if [ ! -f "${SOURCE_CONF}" ]; then
        log "  No knecta.conf in deploy directory. Skipping."
    elif [ ! -f "${DEST_CONF}" ] || ! diff -q "${SOURCE_CONF}" "${DEST_CONF}" >/dev/null 2>&1; then
        log "  Proxy config changed. Updating..."
        cp "${SOURCE_CONF}" "${DEST_CONF}"
        if docker exec proxy-nginx nginx -t 2>&1; then
            docker exec proxy-nginx nginx -s reload
            log "  Proxy reloaded."
        else
            log "  WARNING: nginx config test failed! Check knecta.conf."
        fi
    else
        log "  Proxy config unchanged."
    fi
fi

# =============================================================================
# Update state file to reflect rollback
# =============================================================================
cat > "${STATE_FILE}" <<STATEEOF
# Knecta Update State — written by rollback.sh
# $(date -u +%Y-%m-%dT%H:%M:%SZ)
UPDATE_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FROM_COMMIT="${CURRENT_COMMIT}"
FROM_COMMIT_FULL="$(cd "${REPO_DIR}" && git rev-parse "${CURRENT_COMMIT}" 2>/dev/null || echo "unknown")"
TO_COMMIT="${ROLLBACK_TO}"
TO_COMMIT_FULL="${ROLLBACK_TO_FULL}"
MIGRATIONS_ADDED=""
ROLLBACK="true"
STATEEOF

# =============================================================================
# Verify health
# =============================================================================
log ""
log "Verifying services..."
sleep 3

RUNNING=$(docker compose ps --format '{{.Name}}' 2>/dev/null | wc -l)
log "  Containers running: ${RUNNING}"

API_STATUS=$(docker compose exec -T api wget -qO- http://localhost:3000/api/health/ready 2>/dev/null || echo "FAIL")
if echo "${API_STATUS}" | grep -qi "ok\|up\|status"; then
    log "  API health:    OK"
else
    log "  API health:    WARN (response: ${API_STATUS})"
    log "                 Check: docker compose logs api"
fi

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
log " Rollback complete!"
log "============================================"
log ""
log " Version:  ${CURRENT_COMMIT} -> ${ROLLBACK_TO}"
if [ "${NEEDS_MIGRATION_ROLLBACK}" = "true" ]; then
    log " Migrations rolled back: ${MIGRATION_COUNT}"
fi
log " URL:      https://knecta.marin.cr"
log ""
log "============================================"

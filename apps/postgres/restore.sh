#!/usr/bin/env bash
set -Eeuo pipefail

# restore_wellconnect.sh
# Restores a PostgreSQL custom-format dump (.dump) into a Postgres Docker container.
# - Prompts for: DB username, password, database name, dump location
# - Checks if DB exists; creates if missing
# - Restores with pg_restore (parallel)
# - Verifies restore
# - Deletes the dump file ONLY after successful verification
#
# Run on the VPS (as root or a user with docker access):
#   chmod +x restore_wellconnect.sh
#   ./restore_wellconnect.sh

#######################################
# Helpers
#######################################
log()  { echo -e "[INFO]  $*"; }
warn() { echo -e "[WARN]  $*" >&2; }
die()  { echo -e "[ERROR] $*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  local line_no=${1:-"?"}
  echo -e "[ERROR] Script failed at line ${line_no} (exit code ${exit_code})." >&2
  echo -e "[ERROR] No files were deleted. Fix the issue and re-run." >&2
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

#######################################
# Preconditions
#######################################
require_cmd docker
require_cmd stat
require_cmd awk
require_cmd sed

log "Starting Postgres restore process (Docker-based)."

#######################################
# Prompt for inputs
#######################################
# Default container name based on your environment; allow override.
DEFAULT_CONTAINER="infra-postgres"

read -r -p "Postgres container name [${DEFAULT_CONTAINER}]: " CONTAINER_NAME
CONTAINER_NAME="${CONTAINER_NAME:-$DEFAULT_CONTAINER}"

read -r -p "Database username: " DB_USER
[[ -n "$DB_USER" ]] || die "Database username cannot be empty."

read -r -s -p "Database password (will not echo): " DB_PASS
echo
[[ -n "$DB_PASS" ]] || die "Database password cannot be empty."

read -r -p "Database name to restore into: " DB_NAME
[[ -n "$DB_NAME" ]] || die "Database name cannot be empty."

read -r -p "Full path to dump file (e.g., /opt/db_backup/wellconnect.dump): " DUMP_PATH
[[ -n "$DUMP_PATH" ]] || die "Dump path cannot be empty."

# Parallel jobs (optional)
DEFAULT_JOBS="4"
read -r -p "Parallel restore jobs (-j) [${DEFAULT_JOBS}]: " JOBS
JOBS="${JOBS:-$DEFAULT_JOBS}"
[[ "$JOBS" =~ ^[0-9]+$ ]] || die "Jobs must be a number (got: $JOBS)."
(( JOBS >= 1 )) || die "Jobs must be >= 1."

#######################################
# Validate inputs / environment
#######################################
log "Validating Docker container '${CONTAINER_NAME}' exists and is running..."
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME" \
  || die "Container '$CONTAINER_NAME' is not running. Run 'docker ps' and choose the correct name."

log "Validating dump file exists at '${DUMP_PATH}'..."
[[ -f "$DUMP_PATH" ]] || die "Dump file not found: $DUMP_PATH"

log "Dump file size: $(stat -c%s "$DUMP_PATH") bytes"

#######################################
# Determine container temp path + ensure tools exist
#######################################
CONTAINER_DUMP="/tmp/${DB_NAME}_restore_$$.dump"

log "Checking that pg_restore exists inside the container..."
docker exec -i "$CONTAINER_NAME" sh -lc 'command -v pg_restore >/dev/null 2>&1 && command -v psql >/dev/null 2>&1' \
  || die "pg_restore and/or psql not found inside container '$CONTAINER_NAME'. Is this a Postgres image?"

#######################################
# Copy dump into container
#######################################
log "Copying dump into container: ${CONTAINER_NAME}:${CONTAINER_DUMP}"
docker cp "$DUMP_PATH" "${CONTAINER_NAME}:${CONTAINER_DUMP}"

#######################################
# Check DB exists; create if missing
#######################################
log "Checking whether database '${DB_NAME}' exists..."
DB_EXISTS=$(
  docker exec -e PGPASSWORD="$DB_PASS" -i "$CONTAINER_NAME" \
    sh -lc "psql -U '$DB_USER' -d postgres -tAc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'\" 2>/dev/null" \
    | tr -d '[:space:]' || true
)

if [[ "$DB_EXISTS" == "1" ]]; then
  log "Database '${DB_NAME}' exists. Will restore into it."
else
  log "Database '${DB_NAME}' does NOT exist. Creating it now..."
  docker exec -e PGPASSWORD="$DB_PASS" -i "$CONTAINER_NAME" \
    sh -lc "createdb -U '$DB_USER' '${DB_NAME}'" \
    || die "Failed to create database '${DB_NAME}'. Check user privileges."
  log "Database '${DB_NAME}' created."
fi

#######################################
# Restore
#######################################
log "Restoring dump into '${DB_NAME}' as user '${DB_USER}' (jobs=${JOBS})..."
log "Command: pg_restore -U ${DB_USER} -d ${DB_NAME} --no-owner --no-privileges -j ${JOBS} ${CONTAINER_DUMP}"

docker exec -e PGPASSWORD="$DB_PASS" -i "$CONTAINER_NAME" \
  sh -lc "pg_restore -U '$DB_USER' -d '$DB_NAME' --no-owner --no-privileges -j '$JOBS' '$CONTAINER_DUMP'"

log "Restore completed."

#######################################
# Verification
#######################################
log "Verifying restore..."
# 1) Can connect
docker exec -e PGPASSWORD="$DB_PASS" -i "$CONTAINER_NAME" \
  sh -lc "psql -U '$DB_USER' -d '$DB_NAME' -c 'SELECT 1;' >/dev/null"

# 2) Verify at least some non-system tables exist
TABLE_COUNT=$(
  docker exec -e PGPASSWORD="$DB_PASS" -i "$CONTAINER_NAME" \
    sh -lc "psql -U '$DB_USER' -d '$DB_NAME' -tAc \"SELECT COUNT(*) FROM pg_catalog.pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema');\"" \
    | tr -d '[:space:]'
)

log "Non-system table count: ${TABLE_COUNT}"

if [[ -z "$TABLE_COUNT" || ! "$TABLE_COUNT" =~ ^[0-9]+$ ]]; then
  die "Verification failed: could not determine table count."
fi

if (( TABLE_COUNT <= 0 )); then
  die "Verification failed: restore appears to contain 0 user tables."
fi

log "Verification PASSED."

#######################################
# Cleanup
#######################################
log "Cleaning up temporary dump inside container..."
docker exec -i "$CONTAINER_NAME" sh -lc "rm -f '$CONTAINER_DUMP' || true"

log "Deleting host dump file ONLY after successful verification: ${DUMP_PATH}"
rm -f "$DUMP_PATH"

log "All done. Database '${DB_NAME}' restored successfully and dump file deleted."

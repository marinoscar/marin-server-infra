#!/usr/bin/env bash
# =============================================================================
# backup-postgres-to-s3.sh — Nightly backup of all Postgres DBs to S3
# =============================================================================
# Run by cron at 02:00 America/Chicago (see /opt/infra/docs/postgres-backup-setup.md).
#
# Config:      /opt/infra/shared/backup-postgres-to-s3.env (AWS creds + bucket)
# Per-run log: /opt/infra/shared/backup-logs/backup-<timestamp>.log
# 'latest' symlink: /opt/infra/shared/backup-logs/latest
#
# Strategy: pg_dump --format=custom --compress=zstd:3 per database in parallel,
# pg_restore --list header verification, then aws s3 cp with STANDARD_IA tier.
# 10-day retention is handled by S3 lifecycle, not this script.
# =============================================================================
set -euo pipefail

ENV_FILE="/opt/infra/shared/backup-postgres-to-s3.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE not found" >&2
    exit 2
fi
set -a
. "$ENV_FILE"
set +a

PG_CONTAINER="${PG_CONTAINER:-infra-postgres}"
PG_USER="${PG_USER:-admin}"
STAGE_DIR="/opt/infra/apps/postgres/backups/staging"
LOG_DIR="/opt/infra/shared/backup-logs"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

mkdir -p "$STAGE_DIR" "$LOG_DIR"

# Per-execution log: redirect all output to a unique timestamped file plus
# whatever cron is collecting (which will go to cron-stderr.log).
LOG_FILE="$LOG_DIR/backup-$(date +%Y-%m-%dT%H%M%S%z).log"
exec > >(tee -a "$LOG_FILE") 2>&1
ln -sfn "$(basename "$LOG_FILE")" "$LOG_DIR/latest"

TS() { date -Is; }
RC=0
trap 'rm -rf "$STAGE_DIR"; echo "[$(TS)] Exit: $RC"' EXIT

TODAY=$(date +%F)
S3_PATH="s3://${S3_BUCKET}/${TODAY}"

echo "[$(TS)] === Starting backup for $TODAY -> $S3_PATH ==="
echo "[$(TS)] AWS identity: $(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || echo 'UNKNOWN')"
echo "[$(TS)] Log file:     $LOG_FILE"

# -----------------------------------------------------------------------------
# 1. Globals (roles, role memberships, passwords) -- required for full DR.
# -----------------------------------------------------------------------------
echo "[$(TS)] Dumping globals..."
if docker exec "$PG_CONTAINER" pg_dumpall -U "$PG_USER" --globals-only > "$STAGE_DIR/_globals.sql"; then
    if aws s3 cp "$STAGE_DIR/_globals.sql" "$S3_PATH/_globals.sql" \
        --storage-class STANDARD_IA --no-progress >/dev/null; then
        echo "  OK   _globals.sql ($(du -h "$STAGE_DIR/_globals.sql" | cut -f1))"
    else
        echo "  FAIL _globals.sql (upload error)"
        RC=1
    fi
    rm "$STAGE_DIR/_globals.sql"
else
    echo "  FAIL _globals.sql (pg_dumpall error)"
    RC=1
fi

# -----------------------------------------------------------------------------
# 2. Discover user databases (largest first so big ones start early).
# -----------------------------------------------------------------------------
DBS=$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d postgres -tAc \
    "SELECT datname FROM pg_database
     WHERE datistemplate=false AND datname<>'postgres'
     ORDER BY pg_database_size(datname) DESC")
DB_COUNT=$(echo "$DBS" | grep -c .)
echo "[$(TS)] $DB_COUNT databases to back up: $(echo $DBS | tr '\n' ' ')"

# -----------------------------------------------------------------------------
# 3. Parallel dump -> verify (pg_restore --list) -> upload (STANDARD_IA).
# -----------------------------------------------------------------------------
export PG_CONTAINER PG_USER STAGE_DIR S3_PATH
echo "$DBS" | xargs -I {} -P "$PARALLEL_JOBS" bash -c '
    DB="{}"
    OUT="$STAGE_DIR/${DB}.dump"
    if docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" \
        --format=custom --compress=zstd:3 "$DB" > "$OUT" 2>/dev/null; then
        if docker exec -i "$PG_CONTAINER" pg_restore --list < "$OUT" >/dev/null 2>&1; then
            if aws s3 cp "$OUT" "$S3_PATH/${DB}.dump" --storage-class STANDARD_IA --no-progress >/dev/null; then
                echo "  OK   $DB ($(du -h "$OUT" | cut -f1))"
            else
                echo "  FAIL $DB (upload error)"
            fi
        else
            echo "  FAIL $DB (verification failed)"
        fi
    else
        echo "  FAIL $DB (pg_dump error)"
    fi
    rm -f "$OUT"
'

# -----------------------------------------------------------------------------
# 4. Integrity check: count what actually landed in S3.
# -----------------------------------------------------------------------------
UPLOADED=$(aws s3 ls "$S3_PATH/" 2>/dev/null | wc -l)
EXPECTED=$((DB_COUNT + 1))    # +1 for _globals.sql
echo "[$(TS)] Uploaded $UPLOADED / $EXPECTED objects to $S3_PATH"
if [ "$UPLOADED" -ne "$EXPECTED" ]; then
    echo "[$(TS)] WARN: object count mismatch"
    RC=1
fi

# -----------------------------------------------------------------------------
# 5. Prune local per-execution logs older than $LOG_RETENTION_DAYS days.
# -----------------------------------------------------------------------------
find "$LOG_DIR" -maxdepth 1 -name 'backup-*.log' -type f -mtime "+${LOG_RETENTION_DAYS}" -delete

echo "[$(TS)] === Backup complete ==="
exit $RC

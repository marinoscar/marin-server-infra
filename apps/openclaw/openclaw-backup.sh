#!/usr/bin/env bash
# openclaw-backup.sh
#
# Backs up the OpenClaw configuration directory (.openclaw) to AWS S3.
# Creates a timestamped zip archive, uploads it, and enforces a rolling
# retention policy of 15 copies (deletes the oldest when exceeded).
#
# Prerequisites:
#   - AWS CLI v2 installed on the host
#   - zip command available
#   - .env file with: S3_BUCKET, S3_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#
# Usage:
#   ./openclaw-backup.sh          # Run manually
#   crontab: 0 9 * * *            # Daily at 3 AM CST (9:00 UTC)
#
# Logs are written to: /opt/infra/apps/openclaw/openclaw-backup.log

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

APP_DIR="/opt/infra/apps/openclaw"
SOURCE_DIR="${APP_DIR}/data/home/.openclaw"
LOG="${APP_DIR}/openclaw-backup.log"
MAX_BACKUPS=15

TS="$(date +%Y%m%d%H%M%S)"
ZIP_NAME="bk-${TS}.zip"
TMP_ZIP="/tmp/${ZIP_NAME}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    echo "$(date -Is) $*" | tee -a "${LOG}"
}

cleanup() {
    rm -f "${TMP_ZIP}"
}

on_error() {
    log "ERROR: Backup failed at line $1"
    cleanup
    exit 1
}

trap 'on_error ${LINENO}' ERR

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

log "===== Starting OpenClaw backup ====="

# ---------------------------------------------------------------------------
# Load environment variables from .env
# ---------------------------------------------------------------------------

if [ ! -f "${APP_DIR}/.env" ]; then
    log "ERROR: .env file not found at ${APP_DIR}/.env"
    exit 1
fi

set -a
. "${APP_DIR}/.env"
set +a

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------

if ! command -v aws > /dev/null 2>&1; then
    log "ERROR: AWS CLI is not installed."
    log "Install it with:"
    log "  curl https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip"
    log "  unzip /tmp/awscliv2.zip -d /tmp/aws-install"
    log "  /tmp/aws-install/aws/install"
    exit 1
fi

if ! command -v zip > /dev/null 2>&1; then
    log "ERROR: 'zip' is not installed. Install with: apt install zip"
    exit 1
fi

if [ ! -d "${SOURCE_DIR}" ]; then
    log "ERROR: Source directory not found: ${SOURCE_DIR}"
    exit 1
fi

for var in S3_BUCKET S3_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if [ -z "${!var:-}" ]; then
        log "ERROR: Required variable ${var} is not set in .env"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Create zip archive
# ---------------------------------------------------------------------------

log "Zipping ${SOURCE_DIR} -> ${TMP_ZIP}"
cd "${SOURCE_DIR}"
zip -r "${TMP_ZIP}" .
ZIP_SIZE=$(du -h "${TMP_ZIP}" | cut -f1)
log "Zip created: ${ZIP_NAME} (${ZIP_SIZE})"

# ---------------------------------------------------------------------------
# Upload to S3
# ---------------------------------------------------------------------------

log "Uploading to s3://${S3_BUCKET}/${ZIP_NAME}"
aws s3 cp "${TMP_ZIP}" "s3://${S3_BUCKET}/${ZIP_NAME}" --region "${S3_REGION}"
log "Upload complete"

# ---------------------------------------------------------------------------
# Clean up temp file
# ---------------------------------------------------------------------------

cleanup
log "Temp file removed"

# ---------------------------------------------------------------------------
# Enforce retention policy (keep newest MAX_BACKUPS copies)
# ---------------------------------------------------------------------------

log "Checking retention (max ${MAX_BACKUPS} backups)..."

# List all bk-*.zip files in the bucket, extract filenames, sort by name
BACKUP_LIST=$(aws s3 ls "s3://${S3_BUCKET}/" --region "${S3_REGION}" \
    | grep -oP 'bk-\d{14}\.zip' \
    | sort)

BACKUP_COUNT=$(echo "${BACKUP_LIST}" | grep -c . || true)
log "Found ${BACKUP_COUNT} backups in S3"

if [ "${BACKUP_COUNT}" -gt "${MAX_BACKUPS}" ]; then
    DELETE_COUNT=$((BACKUP_COUNT - MAX_BACKUPS))
    log "Deleting ${DELETE_COUNT} oldest backup(s) to enforce retention..."

    DELETE_LIST=$(echo "${BACKUP_LIST}" | head -n "${DELETE_COUNT}")

    for file in ${DELETE_LIST}; do
        log "Deleting s3://${S3_BUCKET}/${file}"
        aws s3 rm "s3://${S3_BUCKET}/${file}" --region "${S3_REGION}"
    done

    log "Retention cleanup complete"
else
    log "Within retention limit, no cleanup needed"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

log "===== Finished OpenClaw backup ====="
echo "" >> "${LOG}"

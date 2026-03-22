#!/usr/bin/env bash
# openclaw-restore.sh
#
# Restores the OpenClaw configuration directory (.openclaw) from an S3 backup.
# Downloads a specified backup zip, stops the container, replaces the current
# .openclaw directory, and restarts the container.
#
# Safety nets:
#   - Creates a local safety backup of the current .openclaw before any changes
#   - Validates the downloaded zip before replacing anything
#   - Automatic rollback on failure: restores the safety backup if any step fails
#   - Confirmation prompt before destructive operations
#   - The safety backup is preserved until you explicitly remove it
#
# Prerequisites:
#   - AWS CLI v2 installed on the host
#   - unzip command available
#   - .env file with: S3_BUCKET, S3_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#
# Usage:
#   ./openclaw-restore.sh                     # Interactive: lists backups and prompts
#   ./openclaw-restore.sh bk-20260318023153.zip   # Restore a specific backup
#   ./openclaw-restore.sh --list              # List available backups in S3
#
# Logs are written to: /opt/infra/apps/openclaw/openclaw-restore.log

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

APP_DIR="/opt/infra/apps/openclaw"
TARGET_DIR="${APP_DIR}/data/home/.openclaw"
SAFETY_DIR="${APP_DIR}/data/home/.openclaw.pre-restore"
LOG="${APP_DIR}/openclaw-restore.log"
OWNER_UID=1001
OWNER_GID=1001

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    echo "$(date -Is) $*" | tee -a "${LOG}"
}

die() {
    log "ERROR: $*"
    exit 1
}

# Track state for rollback decisions
DOWNLOAD_DONE=false
SAFETY_BACKUP_DONE=false
TARGET_REMOVED=false
TMP_ZIP=""

cleanup() {
    # Remove the downloaded zip if it exists
    if [ -n "${TMP_ZIP}" ] && [ -f "${TMP_ZIP}" ]; then
        rm -f "${TMP_ZIP}"
        log "Cleaned up temp file: ${TMP_ZIP}"
    fi
}

rollback() {
    log "ERROR: Restore failed at line $1 — starting rollback..."

    # If we removed the target and have a safety backup, restore it
    if [ "${TARGET_REMOVED}" = true ] && [ "${SAFETY_BACKUP_DONE}" = true ]; then
        log "Rolling back: restoring safety backup..."
        rm -rf "${TARGET_DIR}"
        mv "${SAFETY_DIR}" "${TARGET_DIR}"
        log "Rollback complete: original .openclaw restored from safety backup"
    elif [ "${TARGET_REMOVED}" = true ]; then
        log "WARNING: Target was removed but no safety backup exists — manual intervention needed"
    fi

    cleanup

    # Try to restart the container so the service is not left down
    log "Attempting to restart the OpenClaw container..."
    cd "${APP_DIR}"
    if docker compose up -d 2>&1 | tee -a "${LOG}"; then
        log "Container restarted"
    else
        log "WARNING: Failed to restart container — manual intervention needed"
    fi

    log "===== Restore FAILED (rolled back) ====="
    echo "" >> "${LOG}"
    exit 1
}

trap 'rollback ${LINENO}' ERR

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

log "===== Starting OpenClaw restore ====="

# ---------------------------------------------------------------------------
# Load environment variables from .env
# ---------------------------------------------------------------------------

if [ ! -f "${APP_DIR}/.env" ]; then
    die ".env file not found at ${APP_DIR}/.env"
fi

set -a
. "${APP_DIR}/.env"
set +a

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------

if ! command -v aws > /dev/null 2>&1; then
    die "AWS CLI is not installed. See docs/openclaw-backup-restore-setup.md for install instructions."
fi

if ! command -v unzip > /dev/null 2>&1; then
    die "'unzip' is not installed. Install with: apt install unzip"
fi

for var in S3_BUCKET S3_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if [ -z "${!var:-}" ]; then
        die "Required variable ${var} is not set in .env"
    fi
done

# ---------------------------------------------------------------------------
# List available backups
# ---------------------------------------------------------------------------

list_backups() {
    log "Listing backups in s3://${S3_BUCKET}/"
    BACKUP_LIST=$(aws s3 ls "s3://${S3_BUCKET}/" --region "${S3_REGION}" \
        | grep -oP 'bk-\d{14}\.zip' \
        | sort)

    if [ -z "${BACKUP_LIST}" ]; then
        die "No backups found in s3://${S3_BUCKET}/"
    fi

    echo ""
    echo "Available backups (newest last):"
    echo "--------------------------------------"

    # Display with human-readable timestamps
    INDEX=0
    while IFS= read -r file; do
        INDEX=$((INDEX + 1))
        # Extract timestamp parts from filename: bk-YYYYMMDDHHMMSS.zip
        TS_RAW="${file#bk-}"
        TS_RAW="${TS_RAW%.zip}"
        YEAR="${TS_RAW:0:4}"
        MONTH="${TS_RAW:4:2}"
        DAY="${TS_RAW:6:2}"
        HOUR="${TS_RAW:8:2}"
        MIN="${TS_RAW:10:2}"
        SEC="${TS_RAW:12:2}"
        printf "  %2d) %s  (%s-%s-%s %s:%s:%s)\n" \
            "${INDEX}" "${file}" "${YEAR}" "${MONTH}" "${DAY}" "${HOUR}" "${MIN}" "${SEC}"
    done <<< "${BACKUP_LIST}"

    echo "--------------------------------------"
    echo ""
}

# ---------------------------------------------------------------------------
# Determine which backup to restore
# ---------------------------------------------------------------------------

# Handle --list flag
if [ "${1:-}" = "--list" ]; then
    list_backups
    exit 0
fi

if [ -n "${1:-}" ]; then
    # Backup filename provided as argument
    ZIP_NAME="$1"
    log "Backup specified via argument: ${ZIP_NAME}"
else
    # Interactive mode: list backups and prompt user to choose
    list_backups

    BACKUP_ARRAY=()
    while IFS= read -r line; do
        BACKUP_ARRAY+=("${line}")
    done <<< "${BACKUP_LIST}"

    TOTAL=${#BACKUP_ARRAY[@]}

    echo "Enter the number of the backup to restore (1-${TOTAL}), or 'q' to quit:"
    read -r CHOICE

    if [ "${CHOICE}" = "q" ] || [ "${CHOICE}" = "Q" ]; then
        log "Restore cancelled by user"
        exit 0
    fi

    # Validate the choice is a number in range
    if ! [[ "${CHOICE}" =~ ^[0-9]+$ ]] || [ "${CHOICE}" -lt 1 ] || [ "${CHOICE}" -gt "${TOTAL}" ]; then
        die "Invalid selection: ${CHOICE}. Must be a number between 1 and ${TOTAL}."
    fi

    ZIP_NAME="${BACKUP_ARRAY[$((CHOICE - 1))]}"
    log "User selected backup #${CHOICE}: ${ZIP_NAME}"
fi

# Validate filename format
if ! [[ "${ZIP_NAME}" =~ ^bk-[0-9]{14}\.zip$ ]]; then
    die "Invalid backup filename: ${ZIP_NAME}. Expected format: bk-YYYYMMDDHHMMSS.zip"
fi

TMP_ZIP="/tmp/${ZIP_NAME}"

# ---------------------------------------------------------------------------
# Download backup from S3
# ---------------------------------------------------------------------------

log "Downloading s3://${S3_BUCKET}/${ZIP_NAME} -> ${TMP_ZIP}"
aws s3 cp "s3://${S3_BUCKET}/${ZIP_NAME}" "${TMP_ZIP}" --region "${S3_REGION}"
DOWNLOAD_DONE=true

# Validate the zip file is not empty and is a valid archive
ZIP_SIZE=$(du -h "${TMP_ZIP}" | cut -f1)
log "Downloaded: ${ZIP_NAME} (${ZIP_SIZE})"

if ! unzip -t "${TMP_ZIP}" > /dev/null 2>&1; then
    die "Downloaded file is not a valid zip archive: ${TMP_ZIP}"
fi

FILE_COUNT=$(unzip -l "${TMP_ZIP}" | tail -1 | awk '{print $2}')
log "Zip validated: ${FILE_COUNT} files inside"

# ---------------------------------------------------------------------------
# Confirmation prompt
# ---------------------------------------------------------------------------

echo ""
echo "=== RESTORE SUMMARY ==="
echo "  Backup file : ${ZIP_NAME}"
echo "  Backup size : ${ZIP_SIZE}"
echo "  Files       : ${FILE_COUNT}"
echo "  Target      : ${TARGET_DIR}"
echo ""
echo "This will:"
echo "  1. Stop the OpenClaw container"
echo "  2. Save current .openclaw to .openclaw.pre-restore (safety backup)"
echo "  3. Replace .openclaw with the contents of ${ZIP_NAME}"
echo "  4. Restart the OpenClaw container"
echo ""
echo "If anything fails, the safety backup will be automatically restored."
echo ""
echo "Proceed? (yes/no):"
read -r CONFIRM

if [ "${CONFIRM}" != "yes" ]; then
    log "Restore cancelled by user"
    cleanup
    exit 0
fi

# ---------------------------------------------------------------------------
# Stop the OpenClaw container
# ---------------------------------------------------------------------------

log "Stopping OpenClaw container..."
cd "${APP_DIR}"
docker compose down 2>&1 | tee -a "${LOG}"
log "Container stopped"

# ---------------------------------------------------------------------------
# Create safety backup of current .openclaw
# ---------------------------------------------------------------------------

if [ -d "${TARGET_DIR}" ]; then
    # Remove any leftover safety backup from a previous restore
    if [ -d "${SAFETY_DIR}" ]; then
        log "Removing previous safety backup at ${SAFETY_DIR}"
        rm -rf "${SAFETY_DIR}"
    fi

    log "Creating safety backup: ${TARGET_DIR} -> ${SAFETY_DIR}"
    cp -a "${TARGET_DIR}" "${SAFETY_DIR}"
    SAFETY_BACKUP_DONE=true
    log "Safety backup created"
else
    log "WARNING: No existing .openclaw directory found — nothing to back up"
fi

# ---------------------------------------------------------------------------
# Replace .openclaw with backup contents
# ---------------------------------------------------------------------------

log "Removing current .openclaw directory..."
rm -rf "${TARGET_DIR}"
TARGET_REMOVED=true

log "Extracting ${ZIP_NAME} -> ${TARGET_DIR}"
mkdir -p "${TARGET_DIR}"
cd "${TARGET_DIR}"
unzip -o "${TMP_ZIP}"

# ---------------------------------------------------------------------------
# Fix ownership and permissions
# ---------------------------------------------------------------------------

log "Setting ownership to ${OWNER_UID}:${OWNER_GID}"
chown -R "${OWNER_UID}:${OWNER_GID}" "${TARGET_DIR}"
chmod 700 "${TARGET_DIR}"
log "Ownership and permissions set"

# ---------------------------------------------------------------------------
# Clean up temp file
# ---------------------------------------------------------------------------

cleanup

# ---------------------------------------------------------------------------
# Restart the OpenClaw container
# ---------------------------------------------------------------------------

log "Starting OpenClaw container..."
cd "${APP_DIR}"
docker compose up -d 2>&1 | tee -a "${LOG}"
log "Container started"

echo ""
echo "The OpenClaw gateway takes approximately 60-70 seconds to initialize."
echo "Check progress with: docker logs --tail 30 openclaw-ssh"
echo ""

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

log "===== Restore completed successfully ====="
log "Safety backup preserved at: ${SAFETY_DIR}"
log "Once verified, you may remove it with: rm -rf ${SAFETY_DIR}"
echo "" >> "${LOG}"

echo "Restore complete. Safety backup is at:"
echo "  ${SAFETY_DIR}"
echo ""
echo "Once you have verified everything works, remove it with:"
echo "  rm -rf ${SAFETY_DIR}"

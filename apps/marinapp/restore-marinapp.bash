#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# MarinApp Restore Script
#
# Purpose:
# - Restore the application source (src/) from backup.zip
# - Then re-run install-marinapp.sh to complete rebuild & restart
#
# Behavior:
# - Fails fast on any error
# - Logs every major step
# - Explains what is happening as it runs
#
# Expected files:
# - backup.zip                (created by install-marinapp.sh)
# - install-marinapp.sh       (same directory)
#
# ============================================================================

ROOT_DIR="/opt/infra/apps/marinapp"
SRC_DIR="${ROOT_DIR}/src"
BACKUP_ZIP="${ROOT_DIR}/backup.zip"
INSTALL_SCRIPT="${ROOT_DIR}/install-marinapp.sh"

log() {
  echo "[restore-marinapp] $*"
}

run() {
  log "RUN: $*"
  "$@"
}

log "=== MarinApp RESTORE starting ==="

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

if [ ! -f "$BACKUP_ZIP" ]; then
  log "ERROR: backup.zip not found at $BACKUP_ZIP"
  log "Restore cannot continue."
  exit 1
fi

if [ ! -f "$INSTALL_SCRIPT" ]; then
  log "ERROR: install-marinapp.sh not found at $INSTALL_SCRIPT"
  log "Restore cannot continue."
  exit 1
fi

# Ensure install script is executable
if [ ! -x "$INSTALL_SCRIPT" ]; then
  log "install-marinapp.sh is not executable. Fixing permissions."
  run chmod +x "$INSTALL_SCRIPT"
fi

# ---------------------------------------------------------------------------
# Remove existing src directory
# ---------------------------------------------------------------------------

if [ -d "$SRC_DIR" ]; then
  log "Removing existing src directory: $SRC_DIR"
  run rm -rf "$SRC_DIR"
else
  log "No existing src directory found. Nothing to remove."
fi

# ---------------------------------------------------------------------------
# Restore src from backup.zip
# ---------------------------------------------------------------------------

log "Restoring src directory from backup.zip"
run bash -lc "
  set -e
  cd '$ROOT_DIR'
  unzip -q 'backup.zip'
"

if [ ! -d "$SRC_DIR" ]; then
  log "ERROR: Restore failed — src directory not found after unzip."
  exit 1
fi

log "src directory successfully restored from backup.zip"

# ---------------------------------------------------------------------------
# Re-run install script to complete rebuild & restart
# ---------------------------------------------------------------------------

log "Running install-marinapp.sh to complete restore process"
run "$INSTALL_SCRIPT"

# ---------------------------------------------------------------------------
# Completion
# ---------------------------------------------------------------------------

log "=== SUCCESS: MarinApp restore completed successfully ==="
log "Source restored, application rebuilt, and services restarted."

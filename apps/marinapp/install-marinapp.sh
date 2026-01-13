#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="/opt/infra/apps/marinapp"
SRC_DIR="${ROOT_DIR}/src"
ROOT_ENV_FILE="${ROOT_DIR}/.env"
WEB_ENV_LINK="${SRC_DIR}/apps/web/.env"

REPO_ZIP_URL="https://github.com/marinoscar/MarinApp/archive/refs/heads/main.zip"

WEB_CFG_JSON_SRC="${ROOT_DIR}/web.config.json"
WEB_CFG_JS_SRC="${ROOT_DIR}/web.config.js"
API_CFG_JSON_SRC="${ROOT_DIR}/api.config.json"

WEB_PUBLIC_DIR="${SRC_DIR}/apps/web/public"
WEB_CFG_JSON_DEST="${WEB_PUBLIC_DIR}/config.json"
WEB_CFG_JS_DEST="${WEB_PUBLIC_DIR}/config.js"

API_SRC_DIR="${SRC_DIR}/apps/api/src"
API_CFG_JSON_DEST="${API_SRC_DIR}/config.json"

log() { echo "[install-marinapp] $*"; }
run() { log "RUN: $*"; "$@"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "ERROR: missing required command: $1"
    exit 1
  }
}

log "=== MarinApp install starting ==="

# --- Dependencies ---
need_cmd unzip
need_cmd docker
need_cmd find
need_cmd head
need_cmd mkdir
need_cmd rm
need_cmd mv
need_cmd cp
need_cmd ln

# Downloader (wget or curl)
if command -v wget >/dev/null 2>&1; then
  DOWNLOADER="wget"
elif command -v curl >/dev/null 2>&1; then
  DOWNLOADER="curl"
else
  log "ERROR: need wget or curl installed"
  exit 1
fi

# --- Ensure root dir exists ---
run mkdir -p "$ROOT_DIR"

# --- Temp workspace ---
TMP_DIR="$(mktemp -d -p "$ROOT_DIR" .install-tmp.XXXXXX)"
ZIP_PATH="${TMP_DIR}/marinapp.zip"
EXTRACT_DIR="${TMP_DIR}/extract"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

run mkdir -p "$EXTRACT_DIR"

# --- Download ---
log "Downloading repo zip to: $ZIP_PATH"
if [ "$DOWNLOADER" = "wget" ]; then
  run wget -q -O "$ZIP_PATH" "$REPO_ZIP_URL"
else
  run curl -fsSL -o "$ZIP_PATH" "$REPO_ZIP_URL"
fi

# --- Extract ---
log "Extracting zip into: $EXTRACT_DIR"
run unzip -q "$ZIP_PATH" -d "$EXTRACT_DIR"

# Find the single top-level extracted directory (GitHub zip format)
TOP_DIR="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [ -z "${TOP_DIR:-}" ] || [ ! -d "$TOP_DIR" ]; then
  log "ERROR: Could not find extracted repo directory in $EXTRACT_DIR"
  exit 1
fi
log "Extracted repo directory: $TOP_DIR"

# --- Replace src atomically-ish (rm then mv) ---
log "Replacing existing src directory: $SRC_DIR"
run rm -rf "$SRC_DIR"
run mv "$TOP_DIR" "$SRC_DIR"

# --- Ensure expected target directories exist ---
run mkdir -p "$(dirname "$WEB_ENV_LINK")"
run mkdir -p "$WEB_PUBLIC_DIR"
run mkdir -p "$API_SRC_DIR"

# --- Link .env for web (if present) ---
if [ -f "$ROOT_ENV_FILE" ]; then
  log "Linking web .env: $WEB_ENV_LINK -> $ROOT_ENV_FILE"
  run ln -snf "$ROOT_ENV_FILE" "$WEB_ENV_LINK"
else
  log "WARNING: $ROOT_ENV_FILE not found. Some steps may fail if env vars are required."
fi

# --- Copy web config files ---
if [ -f "$WEB_CFG_JSON_SRC" ]; then
  log "Copying web config JSON: $WEB_CFG_JSON_SRC -> $WEB_CFG_JSON_DEST"
  run cp -f "$WEB_CFG_JSON_SRC" "$WEB_CFG_JSON_DEST"
else
  log "ERROR: Missing required file: $WEB_CFG_JSON_SRC"
  exit 1
fi

if [ -f "$WEB_CFG_JS_SRC" ]; then
  log "Copying web config JS: $WEB_CFG_JS_SRC -> $WEB_CFG_JS_DEST"
  run cp -f "$WEB_CFG_JS_SRC" "$WEB_CFG_JS_DEST"
else
  log "ERROR: Missing required file: $WEB_CFG_JS_SRC"
  exit 1
fi

# --- Copy api config file ---
if [ -f "$API_CFG_JSON_SRC" ]; then
  log "Copying API config JSON: $API_CFG_JSON_SRC -> $API_CFG_JSON_DEST"
  run cp -f "$API_CFG_JSON_SRC" "$API_CFG_JSON_DEST"
else
  log "ERROR: Missing required file: $API_CFG_JSON_SRC"
  exit 1
fi

# --- Docker compose build & up (with env exported) ---
log "Running docker compose build/up with env exported from $ROOT_ENV_FILE"

run bash -lc "
  set -euo pipefail
  cd '$ROOT_DIR'

  if [ ! -f '.env' ]; then
    echo '[install-marinapp] ERROR: .env not found at $ROOT_DIR/.env'
    exit 1
  fi

  echo '[install-marinapp] Exporting variables from .env into shell'
  set -a
  . ./.env
  set +a

  echo '[install-marinapp] Force clean rebuild of web image'
  docker compose build --no-cache web

  echo '[install-marinapp] Restart the stack'
  docker compose up -d
"

# --- Nginx test + reload in proxy container ---
log "Testing nginx config inside proxy-nginx"
run docker exec proxy-nginx nginx -t

log "Reloading nginx inside proxy-nginx"
run docker exec proxy-nginx nginx -s reload

log "=== SUCCESS: MarinApp install/config/build completed and nginx reloaded with no errors. ==="

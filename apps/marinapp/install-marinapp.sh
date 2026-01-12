#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="/opt/infra/apps/marinapp"
ZIP_PATH="${ROOT_DIR}/marinapp.zip"
SRC_DIR="${ROOT_DIR}/src"
WEB_ENV_LINK="${SRC_DIR}/apps/web/.env"
ROOT_ENV_FILE="${ROOT_DIR}/.env"
REPO_ZIP_URL="https://github.com/marinoscar/MarinApp/archive/refs/heads/main.zip"

echo "[install-marinapp] Starting MarinApp installation."

if [ ! -d "$ROOT_DIR" ]; then
  echo "[install-marinapp] Creating ${ROOT_DIR}."
  mkdir -p "$ROOT_DIR"
fi

echo "[install-marinapp] Downloading repository zip."
wget -O "$ZIP_PATH" "$REPO_ZIP_URL"

if [ -d "$SRC_DIR" ]; then
  echo "[install-marinapp] Removing existing ${SRC_DIR}."
  rm -rf "$SRC_DIR"
fi

echo "[install-marinapp] Extracting zip."
unzip -q "$ZIP_PATH" -d "$ROOT_DIR"

if [ -d "${ROOT_DIR}/MarinApp-main" ]; then
  echo "[install-marinapp] Renaming MarinApp-main to src."
  mv "${ROOT_DIR}/MarinApp-main" "$SRC_DIR"
else
  echo "[install-marinapp] Expected extracted directory ${ROOT_DIR}/MarinApp-main not found."
  exit 1
fi

echo "[install-marinapp] Deleting zip file."
rm -f "$ZIP_PATH"

if [ -f "$ROOT_ENV_FILE" ]; then
  echo "[install-marinapp] Creating symlink for web .env."
  ln -snf "$ROOT_ENV_FILE" "$WEB_ENV_LINK"
else
  echo "[install-marinapp] Expected ${ROOT_ENV_FILE} not found. Please create it before running the app."
fi

echo "[install-marinapp] Installation complete."

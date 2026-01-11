#!/usr/bin/env bash
set -euo pipefail

LE_DIR="/opt/infra/proxy/letsencrypt"
WEBROOT="/opt/infra/proxy/webroot"
LOG="/opt/infra/shared/renew-all-certs.log"

echo "===== $(date -Is) Starting renew-all =====" >> "$LOG"

# Renew any certs that are due (no-op if none are due)
docker run --rm \
  -v "${LE_DIR}:/etc/letsencrypt" \
  -v "${WEBROOT}:/var/www/certbot" \
  certbot/certbot:latest renew --webroot -w /var/www/certbot >> "$LOG" 2>&1

# Reload nginx so it picks up renewed files
docker exec proxy-nginx nginx -t >> "$LOG" 2>&1
docker exec proxy-nginx nginx -s reload >> "$LOG" 2>&1

echo "===== $(date -Is) Finished renew-all =====" >> "$LOG"
echo >> "$LOG"

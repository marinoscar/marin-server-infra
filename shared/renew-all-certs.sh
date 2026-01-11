#!/usr/bin/env bash
set -euo pipefail

LE_DIR="/opt/infra/proxy/letsencrypt"
WEBROOT_HOST="/opt/infra/proxy/webroot"
WEBROOT_CONTAINER="/var/www/certbot"
LOG="/opt/infra/shared/renew-all-certs.log"
TS="$(date -Is)"

echo "===== ${TS} Starting renew-all =====" >> "${LOG}"

# 1) Pre-flight: auto-fix renewal configs that contain host paths
RENEWAL_DIR="${LE_DIR}/renewal"
BACKUP_DIR="${LE_DIR}/renewal-backups"
mkdir -p "${BACKUP_DIR}"

if [ -d "${RENEWAL_DIR}" ]; then
  for conf in "${RENEWAL_DIR}"/*.conf; do
    if [ ! -f "${conf}" ]; then
      continue
    fi

    # Only touch files that contain host-specific paths or incorrect webroot
    if grep -q "/opt/infra/proxy/letsencrypt/" "${conf}" || grep -q "webroot_path *= */opt/infra/proxy/webroot" "${conf}"; then
      echo "Fixing renewal config paths in: ${conf}" >> "${LOG}"

      # Backup before modifying
      cp -a "${conf}" "${BACKUP_DIR}/$(basename "${conf}").${TS}.bak"

      # Replace any host letsencrypt paths with container paths
      # Example: /opt/infra/proxy/letsencrypt/live/... -> /etc/letsencrypt/live/...
      sed -i \
        -e 's|/opt/infra/proxy/letsencrypt/|/etc/letsencrypt/|g' \
        "${conf}"

      # Ensure webroot path matches the certbot container mount point
      # Replace any webroot_path line to /var/www/certbot
      # (Handles: webroot_path = /opt/infra/proxy/webroot)
      sed -i \
        -e "s|^webroot_path *=.*|webroot_path = ${WEBROOT_CONTAINER}|g" \
        "${conf}"

      echo "Updated: ${conf} (backup in ${BACKUP_DIR})" >> "${LOG}"
    fi
  done
else
  echo "WARN: Renewal directory not found: ${RENEWAL_DIR}" >> "${LOG}"
fi

# 2) Renew all certs that are due (no-op if none are due)
docker run --rm \
  -v "${LE_DIR}:/etc/letsencrypt" \
  -v "${WEBROOT_HOST}:${WEBROOT_CONTAINER}" \
  certbot/certbot:latest renew --webroot -w "${WEBROOT_CONTAINER}" >> "${LOG}" 2>&1

# 3) Reload nginx to pick up renewed certs
docker exec proxy-nginx nginx -t >> "${LOG}" 2>&1
docker exec proxy-nginx nginx -s reload >> "${LOG}" 2>&1

echo "===== $(date -Is) Finished renew-all =====" >> "${LOG}"
echo >> "${LOG}"

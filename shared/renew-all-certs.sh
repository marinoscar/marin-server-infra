#!/usr/bin/env bash
set -euo pipefail

LE_DIR="/opt/infra/proxy/letsencrypt"
WEBROOT_HOST="/opt/infra/proxy/webroot"
WEBROOT_CONTAINER="/var/www/certbot"
LOG="/opt/infra/shared/renew-all-certs.log"

TS="$(date -Is)"

echo "===== ${TS} Starting renew-all =====" >> "${LOG}"

RENEWAL_DIR="${LE_DIR}/renewal"
BACKUP_DIR="${LE_DIR}/renewal-backups"
mkdir -p "${BACKUP_DIR}"

fix_one_conf () {
  local conf="$1"
  local before_hash after_hash

  before_hash="$(sha256sum "${conf}" | awk '{print $1}')"

  # Backup
  cp -a "${conf}" "${BACKUP_DIR}/$(basename "${conf}").${TS}.bak"

  # 1) Normalize any host letsencrypt paths to container letsencrypt paths
  #    /opt/infra/proxy/letsencrypt/... -> /etc/letsencrypt/...
  sed -i 's|/opt/infra/proxy/letsencrypt/|/etc/letsencrypt/|g' "${conf}"

  # 2) Normalize webroot paths (two possible formats)
  #    a) renewalparams: webroot_path =
  sed -i "s|^webroot_path *=.*|webroot_path = ${WEBROOT_CONTAINER}|g" "${conf}"

  #    b) webroot_map table (TOML-like) entries can include host paths
  #       Example: [[webroot_map]] or key/value style; we normalize the host webroot path.
  sed -i "s|${WEBROOT_HOST}|${WEBROOT_CONTAINER}|g" "${conf}"

  after_hash="$(sha256sum "${conf}" | awk '{print $1}')"

  if [ "${before_hash}" != "${after_hash}" ]; then
    echo "Fixed renewal config: ${conf}" >> "${LOG}"
    echo "  Backup: ${BACKUP_DIR}/$(basename "${conf}").${TS}.bak" >> "${LOG}"
  else
    # No changes; remove unused backup to avoid noise
    rm -f "${BACKUP_DIR}/$(basename "${conf}").${TS}.bak"
  fi
}

# Fix every renewal config deterministically
if [ -d "${RENEWAL_DIR}" ]; then
  for conf in "${RENEWAL_DIR}"/*.conf; do
    [ -f "${conf}" ] || continue
    fix_one_conf "${conf}"
  done
else
  echo "WARN: Renewal directory not found: ${RENEWAL_DIR}" >> "${LOG}"
fi

# Renew all certs that are due
docker run --rm \
  -v "${LE_DIR}:/etc/letsencrypt" \
  -v "${WEBROOT_HOST}:${WEBROOT_CONTAINER}" \
  certbot/certbot:latest renew --webroot -w "${WEBROOT_CONTAINER}" >> "${LOG}" 2>&1

# Reload nginx to pick up renewed certs
docker exec proxy-nginx nginx -t >> "${LOG}" 2>&1
docker exec proxy-nginx nginx -s reload >> "${LOG}" 2>&1

echo "===== $(date -Is) Finished renew-all =====" >> "${LOG}"
echo >> "${LOG}"

#!/usr/bin/env bash
set -euo pipefail

LE_HOST="/opt/infra/proxy/letsencrypt"
WEBROOT_HOST="/opt/infra/proxy/webroot"

LE_CONTAINER="/etc/letsencrypt"
WEBROOT_CONTAINER="/var/www/certbot"

LOG="/opt/infra/shared/renew-all-certs.log"
TS="$(date -Is)"

echo "===== ${TS} Starting renew-all =====" >> "${LOG}"

RENEWAL_DIR="${LE_HOST}/renewal"
BACKUP_DIR="${LE_HOST}/renewal-backups"
mkdir -p "${BACKUP_DIR}"

fix_conf () {
  local conf="$1"
  local bkp="${BACKUP_DIR}/$(basename "${conf}").${TS}.bak"

  cp -a "${conf}" "${bkp}"

  # Replace ALL occurrences of host paths with container paths
  # 1) letsencrypt base dir
  sed -i "s|${LE_HOST}|${LE_CONTAINER}|g" "${conf}"

  # 2) webroot base dir
  sed -i "s|${WEBROOT_HOST}|${WEBROOT_CONTAINER}|g" "${conf}"

  # Fix the common trailing comma on webroot_path lines:  webroot_path = /var/www/certbot,
  sed -i "s|^webroot_path *= *\\(.*\\),$|webroot_path = \\1|g" "${conf}"

  # If nothing changed, remove the backup to keep things clean
  if diff -q "${conf}" "${bkp}" >/dev/null 2>&1; then
    rm -f "${bkp}"
  else
    echo "Fixed renewal config: ${conf}" >> "${LOG}"
    echo "  Backup: ${bkp}" >> "${LOG}"
  fi
}

# Fix every renewal config before renew
if [ -d "${RENEWAL_DIR}" ]; then
  for conf in "${RENEWAL_DIR}"/*.conf; do
    [ -f "${conf}" ] || continue
    fix_conf "${conf}"
  done
else
  echo "WARN: Renewal directory not found: ${RENEWAL_DIR}" >> "${LOG}"
fi

# Renew all due certs (no-op if none due)
docker run --rm \
  -v "${LE_HOST}:${LE_CONTAINER}" \
  -v "${WEBROOT_HOST}:${WEBROOT_CONTAINER}" \
  certbot/certbot:latest renew --webroot -w "${WEBROOT_CONTAINER}" >> "${LOG}" 2>&1

# Reload nginx to pick up renewed certs
docker exec proxy-nginx nginx -t >> "${LOG}" 2>&1
docker exec proxy-nginx nginx -s reload >> "${LOG}" 2>&1

# Neo4j hook: if graph.marin.cr cert was renewed, re-sync ./ssl and restart neo4j.
# Neo4j does not hot-reload SSL — a container restart is required.
GRAPH_CERT="${LE_HOST}/live/graph.marin.cr/fullchain.pem"
NEO4J_CERT="/opt/infra/apps/neo4j/ssl/fullchain.pem"
if [ -f "${GRAPH_CERT}" ] && [ "${GRAPH_CERT}" -nt "${NEO4J_CERT}" ]; then
  echo "graph.marin.cr cert is newer than Neo4j's copy — syncing..." >> "${LOG}"
  /opt/infra/apps/neo4j/sync-certs.sh >> "${LOG}" 2>&1
  docker restart infra-neo4j >> "${LOG}" 2>&1 || true
  echo "Refreshed Neo4j SSL and restarted container" >> "${LOG}"
fi

echo "===== $(date -Is) Finished renew-all =====" >> "${LOG}"
echo >> "${LOG}"

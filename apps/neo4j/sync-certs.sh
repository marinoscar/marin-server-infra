#!/usr/bin/env bash
# =============================================================================
# sync-certs.sh — Copy Let's Encrypt cert into Neo4j's ssl dir
# =============================================================================
# Location:  /opt/infra/apps/neo4j/sync-certs.sh
# Run as:    root (needs to chown to uid 7474)
#
# Purpose:
#   Neo4j's Bolt SSL policy requires fullchain.pem + privkey.pem to live in a
#   single directory readable by the in-container neo4j user (uid 7474).
#   The Let's Encrypt files at /opt/infra/proxy/letsencrypt/live/<domain>/ are
#   symlinks owned by root with mode 600 on the key — not usable directly.
#
#   This script resolves the symlinks, copies the two files into ./ssl/, and
#   sets ownership/perms so Neo4j can read them.
#
# Called from:
#   - install-neo4j.sh        (initial setup)
#   - /opt/infra/shared/renew-all-certs.sh  (after a renewal touches the cert)
#
# After running, restart the Neo4j container so it picks up the new cert:
#   docker restart infra-neo4j
# =============================================================================
set -euo pipefail

NEO4J_DIR="/opt/infra/apps/neo4j"
DOMAIN="graph.marin.cr"
LE_LIVE="/opt/infra/proxy/letsencrypt/live/${DOMAIN}"

if [ ! -f "${LE_LIVE}/fullchain.pem" ] || [ ! -f "${LE_LIVE}/privkey.pem" ]; then
    echo "ERROR: Let's Encrypt cert not found at ${LE_LIVE}" >&2
    echo "       Issue the cert first (install-neo4j.sh does this automatically)." >&2
    exit 1
fi

mkdir -p "${NEO4J_DIR}/ssl/trusted" "${NEO4J_DIR}/ssl/revoked"

cp -L "${LE_LIVE}/fullchain.pem" "${NEO4J_DIR}/ssl/fullchain.pem"
cp -L "${LE_LIVE}/privkey.pem"   "${NEO4J_DIR}/ssl/privkey.pem"

chown -R 7474:7474 "${NEO4J_DIR}/ssl"
chmod 755 "${NEO4J_DIR}/ssl" "${NEO4J_DIR}/ssl/trusted" "${NEO4J_DIR}/ssl/revoked"
chmod 644 "${NEO4J_DIR}/ssl/fullchain.pem"
chmod 600 "${NEO4J_DIR}/ssl/privkey.pem"

echo "Synced Let's Encrypt cert for ${DOMAIN} into ${NEO4J_DIR}/ssl/"

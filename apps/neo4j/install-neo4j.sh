#!/usr/bin/env bash
# =============================================================================
# install-neo4j.sh — Install Neo4j Community on VPS (end-to-end)
# =============================================================================
# Location:  /opt/infra/apps/neo4j/install-neo4j.sh
# Run as:    root
#
# This script:
#   1. Verifies the directory structure (created by this script if missing)
#   2. Validates .env exists with NEO4J_AUTH
#   3. Issues a Let's Encrypt cert for graph.marin.cr (if not already present)
#   4. Syncs the cert into ./ssl/ with uid 7474 ownership
#   5. Starts Neo4j with docker compose
#   6. Polls until Neo4j responds (plugin download takes ~60-90s on first start)
#   7. Installs the nginx vhost into the proxy and reloads
#   8. Opens UFW port 7687 for public Bolt access
#   9. Verifies end-to-end reachability
#
# Usage:
#   cd /opt/infra/apps/neo4j
#   sudo ./install-neo4j.sh
#
# Prerequisites:
#   - Docker + Docker Compose installed
#   - DNS A record for graph.marin.cr pointing at this VPS
#   - proxy-nginx container running
#   - /opt/infra/apps/neo4j/.env exists with: NEO4J_AUTH=neo4j/<password>
#
# Full reference: /opt/infra/docs/neo4j-setup.md
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NEO4J_DIR="/opt/infra/apps/neo4j"
DOMAIN="graph.marin.cr"
BOLT_PORT="7687"
CERT_EMAIL="oscar@marin.cr"

# Proxy paths
PROXY_CONF_DIR="/opt/infra/proxy/nginx/conf.d"
PROXY_CONF_SRC="${NEO4J_DIR}/graph.conf"
PROXY_CONF_DST="${PROXY_CONF_DIR}/graph.conf"
LE_HOST="/opt/infra/proxy/letsencrypt"
WEBROOT_HOST="/opt/infra/proxy/webroot"
CERT_DIR="${LE_HOST}/live/${DOMAIN}"

TOTAL_STEPS=9
log() { echo "[neo4j] $*"; }

# ---------------------------------------------------------------------------
# Step 1: Directory structure
# ---------------------------------------------------------------------------
log "============================================"
log " Neo4j Community Installer"
log "============================================"
log ""
log "[1/${TOTAL_STEPS}] Verifying directory structure..."

mkdir -p \
    "${NEO4J_DIR}/data" \
    "${NEO4J_DIR}/logs" \
    "${NEO4J_DIR}/plugins" \
    "${NEO4J_DIR}/conf" \
    "${NEO4J_DIR}/ssl/trusted" \
    "${NEO4J_DIR}/ssl/revoked" \
    "${NEO4J_DIR}/backups"

log "  Directories ready."

# ---------------------------------------------------------------------------
# Step 2: .env validation
# ---------------------------------------------------------------------------
log ""
log "[2/${TOTAL_STEPS}] Checking environment file..."

if [ ! -f "${NEO4J_DIR}/.env" ]; then
    log ""
    log "  ERROR: .env file not found at ${NEO4J_DIR}/.env"
    log ""
    log "  Create it with the required value:"
    log ""
    log "    nano ${NEO4J_DIR}/.env"
    log ""
    log "  Contents:"
    log "    NEO4J_AUTH=neo4j/\$(openssl rand -hex 24)"
    log ""
    log "  Then run this script again."
    exit 1
fi

set -a
. "${NEO4J_DIR}/.env"
set +a

if [ -z "${NEO4J_AUTH:-}" ]; then
    log "  ERROR: NEO4J_AUTH is missing from .env"
    exit 1
fi

NEO4J_USER="$(echo "${NEO4J_AUTH}" | cut -d/ -f1)"
NEO4J_PASSWORD="$(echo "${NEO4J_AUTH}" | cut -d/ -f2-)"

if [ -z "${NEO4J_USER}" ] || [ -z "${NEO4J_PASSWORD}" ]; then
    log "  ERROR: NEO4J_AUTH must be in the form 'user/password'"
    exit 1
fi

log "  .env file found and validated."

# ---------------------------------------------------------------------------
# Step 3: Issue Let's Encrypt certificate (if missing)
# ---------------------------------------------------------------------------
log ""
log "[3/${TOTAL_STEPS}] Checking SSL certificate for ${DOMAIN}..."

if [ -f "${CERT_DIR}/fullchain.pem" ]; then
    log "  Certificate already exists. Skipping issuance."
else
    log "  No certificate found. Issuing via Let's Encrypt..."

    # Deploy a temporary HTTP-only config so certbot can reach the ACME challenge
    cat > "${PROXY_CONF_DST}" << TEMP_NGINX_EOF
# Temporary HTTP-only config for Let's Encrypt issuance
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 503 "Certificate pending";
    }
}
TEMP_NGINX_EOF

    if docker exec proxy-nginx nginx -t 2>/dev/null; then
        docker exec proxy-nginx nginx -s reload
        log "  Temporary HTTP config deployed."
    else
        log "  ERROR: nginx config validation failed."
        exit 1
    fi

    docker run --rm \
        -v "${LE_HOST}:/etc/letsencrypt" \
        -v "${WEBROOT_HOST}:/var/www/certbot" \
        certbot/certbot:latest certonly \
            --webroot -w /var/www/certbot \
            -d "${DOMAIN}" \
            --non-interactive \
            --agree-tos \
            --email "${CERT_EMAIL}"

    if [ ! -f "${CERT_DIR}/fullchain.pem" ]; then
        log "  ERROR: Certificate was not created. Check certbot output above."
        exit 1
    fi

    log "  Certificate issued."
fi

# ---------------------------------------------------------------------------
# Step 4: Sync cert into ./ssl with uid 7474
# ---------------------------------------------------------------------------
log ""
log "[4/${TOTAL_STEPS}] Syncing certificate into Neo4j ssl directory..."

bash "${NEO4J_DIR}/sync-certs.sh"

# ---------------------------------------------------------------------------
# Step 5: Start Neo4j
# ---------------------------------------------------------------------------
log ""
log "[5/${TOTAL_STEPS}] Starting Neo4j container..."

cd "${NEO4J_DIR}"
docker compose up -d

log "  Container started."

# ---------------------------------------------------------------------------
# Step 6: Wait for Neo4j to be ready
# ---------------------------------------------------------------------------
log ""
log "[6/${TOTAL_STEPS}] Waiting for Neo4j to initialize (plugins download on first start)..."

NEO4J_READY=false
for i in $(seq 1 90); do
    if docker exec infra-neo4j cypher-shell -u "${NEO4J_USER}" -p "${NEO4J_PASSWORD}" 'RETURN 1' >/dev/null 2>&1; then
        NEO4J_READY=true
        break
    fi
    sleep 2
done

if [ "${NEO4J_READY}" = "false" ]; then
    log "  WARNING: Neo4j did not become ready within 180 seconds."
    log "           Check: docker logs --tail 100 infra-neo4j"
else
    log "  Neo4j is responding to Cypher queries."
fi

# ---------------------------------------------------------------------------
# Step 7: Install nginx vhost and reload
# ---------------------------------------------------------------------------
log ""
log "[7/${TOTAL_STEPS}] Installing VPS proxy config..."

cp "${PROXY_CONF_SRC}" "${PROXY_CONF_DST}"
log "  Config copied to ${PROXY_CONF_DST}."

if docker exec proxy-nginx nginx -t 2>/dev/null; then
    docker exec proxy-nginx nginx -s reload
    log "  VPS proxy reloaded."
else
    log "  ERROR: nginx config validation failed after installing graph.conf."
    log "  Check: docker exec proxy-nginx nginx -t"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 8: Open UFW for Bolt
# ---------------------------------------------------------------------------
log ""
log "[8/${TOTAL_STEPS}] Configuring firewall for Bolt..."

if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "^${BOLT_PORT}/tcp"; then
        log "  UFW already allows ${BOLT_PORT}/tcp."
    else
        ufw allow "${BOLT_PORT}/tcp" comment "Neo4j Bolt"
        log "  UFW: opened ${BOLT_PORT}/tcp."
    fi
else
    log "  ufw not installed — skipping firewall step."
fi

# ---------------------------------------------------------------------------
# Step 9: Verify
# ---------------------------------------------------------------------------
log ""
log "[9/${TOTAL_STEPS}] Verifying services..."
sleep 2

LOCAL_CODE=$(curl -so /dev/null -w '%{http_code}' "http://127.0.0.1:7474/" 2>/dev/null || echo "000")
log "  Browser (localhost):    HTTP ${LOCAL_CODE}"

HTTPS_CODE=$(curl -so /dev/null -w '%{http_code}' "https://${DOMAIN}/" 2>/dev/null || echo "000")
log "  Browser (public HTTPS): HTTP ${HTTPS_CODE}"

if openssl s_client -connect "${DOMAIN}:${BOLT_PORT}" -servername "${DOMAIN}" </dev/null 2>/dev/null | grep -q "BEGIN CERTIFICATE"; then
    log "  Bolt TLS handshake:     OK"
else
    log "  Bolt TLS handshake:     WARN — could not verify (check externally with: openssl s_client -connect ${DOMAIN}:${BOLT_PORT})"
fi

log ""
log "============================================"
log " Neo4j installation complete."
log "============================================"
log ""
log "  Browser UI:     https://${DOMAIN}"
log "  Bolt endpoint:  neo4j+s://${DOMAIN}:${BOLT_PORT}"
log "  Username:       ${NEO4J_USER}"
log "  Password:       (set in .env)"
log ""
log "  Logs:           docker logs --tail 100 infra-neo4j"
log "  Cypher shell:   docker exec -it infra-neo4j cypher-shell -u ${NEO4J_USER} -p \$NEO4J_PASSWORD"
log ""
log "============================================"

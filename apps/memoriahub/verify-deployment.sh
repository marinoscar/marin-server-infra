#!/usr/bin/env bash
# =============================================================================
# verify-deployment.sh — Confirm the RUNNING MemoriaHub containers were built
# from the expected git commit.
# =============================================================================
# Background: the web app is a static build baked into its image, and the api is
# likewise compiled at image-build time. A merged feature is only actually LIVE
# once its image is rebuilt AND the container is recreated from that image. On
# 2026-07-15 an aborted update.sh left the web container running a pre-feature
# image even though the code was merged — invisible without grepping the bundle.
#
# update.sh / install-memoriahub.sh now stamp each image at build time with the
# deployed commit as the OCI label org.opencontainers.image.revision (see the
# build.labels blocks in compose.yml). This script reads that label back off the
# running containers and compares it to the deployed tree and origin/main, so
# "is my code actually deployed?" is one command instead of guesswork.
#
# Usage:  sudo /opt/infra/apps/memoriahub/verify-deployment.sh
# Exit:   0 = all in sync, 1 = drift detected (details printed).
# =============================================================================
set -uo pipefail

MEMORIAHUB_DIR="/opt/infra/apps/memoriahub"
REPO_DIR="${MEMORIAHUB_DIR}/repo"
BRANCH="main"
LABEL="org.opencontainers.image.revision"
CONTAINERS="memoriahub-api memoriahub-web"

drift=0

# --- deployed tree + origin/main ---
git -C "${REPO_DIR}" fetch origin --quiet 2>/dev/null || true
deployed_tree="$(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?')"
origin_main="$(git -C "${REPO_DIR}" rev-parse --short "origin/${BRANCH}" 2>/dev/null || echo '?')"

printf 'origin/%-10s %s\n' "${BRANCH}:" "${origin_main}"

status="OK"
if [ "${deployed_tree}" != "${origin_main}" ]; then status="BEHIND origin/${BRANCH}"; drift=1; fi
printf '%-18s %s  %s\n' "deployed tree:" "${deployed_tree}" "${status}"

# --- each running container's baked revision label ---
for c in ${CONTAINERS}; do
    rev="$(docker inspect "${c}" --format "{{index .Config.Labels \"${LABEL}\"}}" 2>/dev/null)"
    if [ -z "${rev}" ]; then
        printf '%-18s %s\n' "${c}:" "NO LABEL (image predates the stamp — rebuild via update.sh)"
        drift=1
        continue
    fi
    status="OK"
    if [ "${rev}" != "${deployed_tree}" ]; then status="STALE (rebuild+recreate needed)"; drift=1; fi
    printf '%-18s %s  %s\n' "${c}:" "${rev}" "${status}"
done

echo
if [ "${drift}" -eq 0 ]; then
    echo "All containers match the deployed tree at origin/${BRANCH}. In sync."
else
    echo "Drift detected. Run: cd ${MEMORIAHUB_DIR} && sudo ./update.sh"
fi
exit "${drift}"

#!/usr/bin/env bash
# =============================================================================
# check-cert-health.sh
# -----------------------------------------------------------------------------
# Safety net for TLS renewals. For every Let's Encrypt domain on this box it
# compares the certificate nginx is ACTUALLY serving on the wire (127.0.0.1:443
# with SNI) against the cert on disk, and against the clock. It exists because a
# renewed cert on disk is worthless until nginx reloads it — this catches the
# gap that broke shellkeep (renewed on disk May 22, but nginx kept serving the
# old cert in memory until it expired Jun 20).
#
# Flags, per domain:
#   - EXPIRED / expiring within ${WARN_DAYS} days (served cert)
#   - SERVED cert older than the DISK cert  ->  a reload was missed
#
# Logs per-execution to /opt/infra/shared/cert-health-logs/ with a 'latest'
# symlink, and self-prunes logs older than ${LOG_RETENTION_DAYS} days.
# Exit code: 0 = all healthy, 1 = one or more problems found.
# =============================================================================
set -euo pipefail

LE_LIVE="/opt/infra/proxy/letsencrypt/live"
HTTPS_ADDR="127.0.0.1:443"
WARN_DAYS="${WARN_DAYS:-14}"
LOG_DIR="/opt/infra/shared/cert-health-logs"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/cert-health-$(date +%Y-%m-%dT%H%M%S%z).log"
exec > >(tee -a "$LOG_FILE") 2>&1
ln -sfn "$(basename "$LOG_FILE")" "$LOG_DIR/latest"

now_epoch="$(date +%s)"
problems=0

echo "===== $(date -Is) cert health check (warn < ${WARN_DAYS}d) ====="

# notAfter epoch of the cert served on the wire for an SNI host ("" if unreachable)
served_notafter_epoch () {
  local host="$1" pem
  pem="$(echo | openssl s_client -connect "$HTTPS_ADDR" -servername "$host" 2>/dev/null)" || return 0
  echo "$pem" | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//' \
    | { read -r d || true; [ -n "${d:-}" ] && date -d "$d" +%s || true; }
}

# notAfter epoch of the cert on disk ("" if missing)
disk_notafter_epoch () {
  local host="$1" f="$LE_LIVE/$1/fullchain.pem"
  [ -f "$f" ] || return 0
  date -d "$(openssl x509 -noout -enddate -in "$f" 2>/dev/null | sed 's/^notAfter=//')" +%s 2>/dev/null || true
}

for dir in "$LE_LIVE"/*/; do
  [ -d "$dir" ] || continue
  domain="$(basename "$dir")"

  served="$(served_notafter_epoch "$domain")"
  disk="$(disk_notafter_epoch "$domain")"

  if [ -z "$served" ]; then
    echo "NOTE   ${domain}: not serving HTTPS on ${HTTPS_ADDR} (SNI) — skipped"
    continue
  fi

  days_left=$(( (served - now_epoch) / 86400 ))

  if [ "$served" -le "$now_epoch" ]; then
    echo "ERROR  ${domain}: SERVED cert is EXPIRED (${days_left}d)"
    problems=$((problems + 1))
  elif [ "$days_left" -lt "$WARN_DAYS" ]; then
    echo "WARN   ${domain}: SERVED cert expires in ${days_left}d"
    problems=$((problems + 1))
  else
    echo "OK     ${domain}: ${days_left}d left"
  fi

  # Served older than disk => certbot renewed but nginx never reloaded it.
  if [ -n "$disk" ] && [ "$disk" -gt "$served" ]; then
    gap=$(( (disk - served) / 86400 ))
    echo "ERROR  ${domain}: a NEWER cert (${gap}d) is on disk but NOT served — nginx reload was missed"
    problems=$((problems + 1))
  fi
done

# Prune old per-execution logs.
find "$LOG_DIR" -maxdepth 1 -name 'cert-health-*.log' -type f -mtime "+${LOG_RETENTION_DAYS}" -delete 2>/dev/null || true

if [ "$problems" -gt 0 ]; then
  echo "===== $(date -Is) DONE — ${problems} problem(s) found ====="
  exit 1
fi
echo "===== $(date -Is) DONE — all certs healthy ====="

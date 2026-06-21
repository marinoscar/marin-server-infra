# TLS Certificate Renewal (Certbot + Docker + Nginx)

This document describes **how TLS certificate renewal is implemented** in this infrastructure, **why it is structured this way**, and **how to verify it is working**.

It is written to be re‑used months or years later without re‑learning the same lessons.

---

## High‑level design

### Key decisions

* **Certbot runs in Docker**, not on the host
* Certificates are stored **on the host filesystem** and mounted into:

  * the Certbot container (for renewal)
  * the Nginx container (for serving TLS)
* **One shared renewal script** renews *all* certificates
* Renewal is triggered via **cron**
* Nginx is reloaded automatically after renewals
* **A single failing certificate must never block the Nginx reload** (see the
  "renewed on disk but not served" incident below)
* **An independent health check** verifies the certificate Nginx is actually
  serving *on the wire* — not just what is on disk

This keeps the system:

* deterministic
* auditable
* Docker‑first
* easy to debug

---

## Filesystem layout

Relevant directories:

```
/opt/infra
  proxy/
    letsencrypt/          # All certbot state (host)
      live/
      archive/
      renewal/
    webroot/              # ACME HTTP‑01 challenge files
  shared/
    renew-all-certs.sh    # Central renewal script (cron: 03:17 daily)
    renew-all-certs.log   # Renewal log (rolling)
    check-cert-health.sh  # Safety-net wire-cert check (cron: 06:47 daily)
    cert-health-logs/     # Per-execution health-check logs + 'latest' symlink
```

Important rule:

> **Certbot inside Docker only understands container paths.**
>
> Any renewal config referencing host paths will break renewals.

---

## Why renewal configs must use container paths

Certbot runs in Docker with these mounts:

```
-v /opt/infra/proxy/letsencrypt:/etc/letsencrypt
-v /opt/infra/proxy/webroot:/var/www/certbot
```

Therefore:

| Host path                      | Container path     |
| ------------------------------ | ------------------ |
| `/opt/infra/proxy/letsencrypt` | `/etc/letsencrypt` |
| `/opt/infra/proxy/webroot`     | `/var/www/certbot` |

If a renewal file references host paths (for example `cert = /opt/infra/...`), Certbot inside Docker **cannot validate the certificate lineage** and fails with:

```
expected .../cert.pem to be a symlink
```

This was the root cause of an early renewal failure that was fixed.

---

## ⚠️ Critical lesson: a renewed cert on disk is NOT a served cert

This is the single most important failure mode in this system, because it is
**silent** and **delayed** — it surfaces only when a certificate actually
expires, which can be weeks after the underlying breakage.

### What happened (shellkeep.marin.cr outage, June 2026)

* Certbot renewed `shellkeep.marin.cr` on disk (valid for another ~90 days).
* But **Nginx kept serving the OLD certificate from memory** and was never
  reloaded.
* That was harmless right up until the *old* in‑memory cert expired — at which
  point the site broke with `ERR_CERT_DATE_INVALID`, even though a perfectly
  valid certificate was sitting on disk.

### Why the reload was skipped (the real root cause)

The renewal script used `set -euo pipefail`. **`certbot renew` exits non‑zero if
ANY single certificate fails to renew.** One certificate (`portainer.marin.cr`)
was failing every night because its renewal config pointed at a **deleted Let's
Encrypt ACME account**. Under `set -e`, that non‑zero exit **aborted the whole
script before the `nginx -s reload` line ever ran**.

The result was a slow‑motion outage generator: every night certbot renewed the
healthy certs on disk, the script aborted before reloading Nginx, and each
renewed cert then quietly waited behind its stale in‑memory copy until that copy
expired. ShellKeep was simply the first domain to cross its expiry date.

### The two fixes (both now in place)

1. **The renewal script no longer lets a single cert failure abort the reload.**
   `certbot renew`'s exit code is captured and logged, then the script continues
   and **always** attempts the Nginx reload (guarded by `nginx -t`). If the
   config is invalid, it writes a loud `ERROR` to the log instead of silently
   leaving stale certs in place.

2. **An independent health check (`check-cert-health.sh`)** inspects the cert
   Nginx is actually serving on the wire for every domain and flags anything
   expired, expiring soon, or **newer on disk than what is served** (i.e. a
   missed reload). This catches the failure mode even if the renewal logic ever
   regresses again.

### Lesson for the future

> When a "renewed" certificate is not being served, **the problem is almost
> always a missed/blocked `nginx -s reload`, not certbot.** Check the cert on the
> wire (`openssl s_client`), not just the file on disk.

---

## The renewal script

### Location

```
/opt/infra/shared/renew-all-certs.sh
```

### Responsibilities

The script does **five things**:

1. **Normalize all renewal configs**

   * Rewrites host paths → container paths
   * Fixes malformed `webroot_path` entries
   * Backs up original configs before modifying

2. **Run certbot renew** (Docker) — capturing its exit code **without aborting**,
   so a single failing cert cannot block the rest of the pipeline

3. **Reload Nginx** whenever the config is valid (`nginx -t`); on invalid config
   it logs a loud `ERROR` instead of leaving renewed certs unserved

4. **Run the health check** (`check-cert-health.sh`) at the end to verify what is
   actually being served

5. **Log everything** for later audit/debugging

---

## Script behavior (important)

* It **always** rewrites renewal configs before running certbot
* It is **idempotent** (safe to run repeatedly)
* If no certs are due, nothing is changed
* Nginx reload is safe even when nothing renews
* **A single cert failure never aborts the reload** (the lesson above)

This guarantees future certificates won’t re‑introduce broken paths, and that a
healthy cert can never silently fail to be served because of an unrelated cert.

---

## The health-check script (safety net)

### Location

```
/opt/infra/shared/check-cert-health.sh
```

### What it does

For **every** Let's Encrypt domain it compares the certificate Nginx is actually
serving on the wire (`127.0.0.1:443` with SNI) against the cert on disk and
against the clock, and flags per domain:

* `EXPIRED` / expiring within `WARN_DAYS` (default **14**) days — served cert
* a cert **newer on disk than what is served** → a reload was missed

It logs **per execution** to `shared/cert-health-logs/` with a `latest` symlink
and self‑prunes logs older than 30 days (same convention as the Postgres backup
job). Exit code `0` = all healthy, `1` = at least one problem.

It runs both **standalone via cron** and **at the end of every renewal run**.

### Read the latest report

```bash
cat /opt/infra/shared/cert-health-logs/latest
```

Healthy output looks like:

```
OK     shellkeep.marin.cr: 59d left
OK     proxy.marin.cr: 34d left
...
===== ... DONE — all certs healthy =====
```

---

## Cron configuration

Both jobs run under **root cron**:

```cron
17 3 * * * /opt/infra/shared/renew-all-certs.sh     # renew + reload + health check
47 6 * * * /opt/infra/shared/check-cert-health.sh   # independent daily safety net
```

* The renewal job runs once per day; certbot internally decides whether renewal
  is needed (certs renew only when **< 30 days** remaining).
* The standalone health check runs at a separate time so a problem is surfaced
  even on days when nothing renews.

---

## Logs and verification

### Renewal log

```
/opt/infra/shared/renew-all-certs.log
```

This log shows:

* script start/end timestamps
* which renewal configs were fixed
* certbot renewal decisions
* nginx reload status (`OK: nginx config valid — reloaded` or a loud `ERROR`)
* an inline health-check summary

A healthy run now **always** ends with a `Finished renew-all` line. If you see a
run that stops at `1 renew failure(s)` with **no** `Finished` line, that is the
old aborting behavior — the script has regressed and is no longer reloading
Nginx.

### Health-check log

```
/opt/infra/shared/cert-health-logs/latest
```

---

## Manual verification commands

### 1. Run the renewal script manually

```bash
/opt/infra/shared/renew-all-certs.sh
```

### 2. Run the health check manually

```bash
/opt/infra/shared/check-cert-health.sh; echo "exit=$?"
```

### 3. Inspect the last renewal log entries

```bash
tail -n 120 /opt/infra/shared/renew-all-certs.log
```

### 4. Confirm renewal configs are clean

```bash
grep -R "/opt/infra/proxy" /opt/infra/proxy/letsencrypt/renewal || true
```

Expected: **no output**.

### 5. Check what is being served ON THE WIRE (not just on disk)

```bash
echo | openssl s_client -connect 127.0.0.1:443 -servername shellkeep.marin.cr 2>/dev/null \
  | openssl x509 -noout -dates -subject
```

### 6. Check the cert file on disk

```bash
openssl x509 -enddate -noout -in /opt/infra/proxy/letsencrypt/live/pgadmin.marin.cr/fullchain.pem
```

If commands 5 and 6 disagree, Nginx has not reloaded the renewed cert — run
`docker exec proxy-nginx nginx -s reload`.

---

## Common failure modes (and fixes)

### ❌ Renewal config parsefail

**Symptom**:

```
expected .../cert.pem to be a symlink
```

**Cause**: renewal config contains host paths.

**Fix**: run `renew-all-certs.sh` (it rewrites configs automatically).

---

### ❌ `ERR_CERT_DATE_INVALID` in the browser, but the cert on disk is valid

**Cause**: Nginx is serving an old certificate from memory; the renewed cert on
disk was never reloaded (historically because an unrelated cert failure aborted
the renewal script — see the critical lesson above).

**Fix**:

```bash
docker exec proxy-nginx nginx -t        # must pass first
docker exec proxy-nginx nginx -s reload
```

Then confirm with verification command #5.

---

### ❌ `certbot renew` reports `1 renew failure(s)` for one domain

**Symptom** (in the renewal log):

```
Failed to renew certificate <domain> with error: Account at
/etc/letsencrypt/accounts/.../<id> does not exist
```

**Cause**: that domain's renewal config (`proxy/letsencrypt/renewal/<domain>.conf`)
references an **ACME `account` id that no longer exists** (e.g. a stale ACMEv1
account, or one that was deleted).

**Fix**: point it at a valid account id used by the other certs. Find a working
account:

```bash
grep -h '^account' /opt/infra/proxy/letsencrypt/renewal/*.conf | sort | uniq -c
```

Edit the broken `account = ...` line to match the common (working) id, then
validate without hitting rate limits:

```bash
docker run --rm \
  -v /opt/infra/proxy/letsencrypt:/etc/letsencrypt \
  -v /opt/infra/proxy/webroot:/var/www/certbot \
  certbot/certbot:latest renew --cert-name <domain> --webroot -w /var/www/certbot --dry-run
```

Expect `all simulated renewals succeeded`.

> Why this matters: because of `set -e`, a single failing account used to abort
> the entire nightly script *before* Nginx reloaded — which is how it silently
> broke every other domain. The script is now hardened against this, but the
> underlying broken account should still be fixed so renewals stay clean.

---

### ❌ 502 Bad Gateway after renewal

**Cause**: Nginx not reloaded.

**Fix**:

```bash
docker exec proxy-nginx nginx -s reload
```

---

## Design principles (why this works long‑term)

* One authoritative renewal script
* No per‑app cert logic
* A single cert failure cannot take down the reload
* The served cert is verified independently of the disk cert
* Docker‑native
* Fully observable via logs
* Safe to re‑run at any time

This makes certificate management boring — which is exactly what you want.

---

## Final checklist

✔ Renewal script exists and executable
✔ Renewal script never aborts before the Nginx reload
✔ Health-check script exists and executable
✔ Both cron jobs configured (renewal 03:17, health check 06:47)
✔ Renewal configs normalized
✔ Nginx reload automated
✔ Served certs verified on the wire, not just on disk
✔ Logs verified

TLS renewal is now **hands‑off and production‑safe**.

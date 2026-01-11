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
    renew-all-certs.sh    # Central renewal script
    renew-all-certs.log   # Renewal log
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

This was the root cause of the renewal failure that was fixed.

---

## The renewal script

### Location

```
/opt/infra/shared/renew-all-certs.sh
```

### Responsibilities

The script does **four things**:

1. **Normalize all renewal configs**

   * Rewrites host paths → container paths
   * Fixes malformed `webroot_path` entries
   * Backs up original configs before modifying

2. **Run certbot renew** (Docker)

3. **Reload Nginx** if configuration is valid

4. **Log everything** for later audit/debugging

---

## Script behavior (important)

* It **always** rewrites renewal configs before running certbot
* It is **idempotent** (safe to run repeatedly)
* If no certs are due, nothing is changed
* Nginx reload is safe even when nothing renews

This guarantees future certificates won’t re‑introduce broken paths.

---

## Cron configuration

### Cron job

The renewal [script](https://github.com/marinoscar/marin-server-infra/blob/5229466451276a065d0907ef19bbaf02df10e4f3/shared/renew-all-certs.sh) is executed daily via root cron:

```cron
17 3 * * * /opt/infra/shared/renew-all-certs.sh
```

* Runs once per day
* Certbot internally decides whether renewal is needed
* Let’s Encrypt best practice is daily or twice daily checks

### Why daily is correct

* Certificates renew only when **< 30 days** remaining
* Daily checks minimize expiration risk
* Low overhead

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
* nginx reload status

Example healthy output:

```
Processing /etc/letsencrypt/renewal/admin.marin.cr.conf
Certificate not yet due for renewal

Processing /etc/letsencrypt/renewal/pgadmin.marin.cr.conf
Certificate not yet due for renewal

The following certificates are not due for renewal yet:
  /etc/letsencrypt/live/admin.marin.cr/fullchain.pem expires on 2026‑04‑11
```

This is **success**, not a problem.

---

## Manual verification commands

### 1. Run the renewal script manually

```bash
/opt/infra/shared/renew-all-certs.sh
```

### 2. Inspect the last log entries

```bash
tail -n 120 /opt/infra/shared/renew-all-certs.log
```

### 3. Confirm renewal configs are clean

```bash
grep -R "/opt/infra/proxy" /opt/infra/proxy/letsencrypt/renewal || true
```

Expected: **no output**.

### 4. Check certificate expiration dates

```bash
openssl x509 -enddate -noout -in /opt/infra/proxy/letsencrypt/live/pgadmin.marin.cr/fullchain.pem
```

---

## Common failure modes (and fixes)

### ❌ Renewal config parsefail

**Symptom**:

```
expected .../cert.pem to be a symlink
```

**Cause**:

* Renewal config contains host paths

**Fix**:

* Run `renew-all-certs.sh` (it rewrites configs automatically)

---

### ❌ 502 Bad Gateway after renewal

**Cause**:

* Nginx not reloaded

**Fix**:

```bash
docker exec proxy-nginx nginx -s reload
```

---

## Design principles (why this works long‑term)

* One authoritative renewal script
* No per‑app cert logic
* Docker‑native
* Fully observable via logs
* Safe to re‑run at any time

This makes certificate management boring — which is exactly what you want.

---

## Final checklist

✔ Renewal script exists and executable
✔ Cron job configured
✔ Renewal configs normalized
✔ Nginx reload automated
✔ Logs verified

TLS renewal is now **hands‑off and production‑safe**.

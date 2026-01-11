# PostgreSQL + pgAdmin + Nginx + Let’s Encrypt (Ubuntu VPS) — `/opt/infra` Runbook

This runbook documents the **exact working** installation pattern for:

* **PostgreSQL (Docker)** exposed publicly on **5432**
* **pgAdmin (Docker)** behind **Nginx reverse proxy** at **[https://pgadmin.marin.cr](https://pgadmin.marin.cr)**
* **Nginx reverse proxy** running in Docker using **`network_mode: host`** (important constraint)
* **Let’s Encrypt TLS** via **Certbot (webroot method)**

It includes the **lessons learned** and the troubleshooting steps that mattered.

> Operator preferences honored:
>
> * Use **nano**
> * Prefer explicit commands and verification after each step
> * No secrets committed to Git

---

## 0) Key architecture decisions

### Why PostgreSQL is installed in Docker

* Aligns with the platform strategy: **Docker + Compose** for services.
* Version pinning (e.g., Postgres 16) and easy portability.
* Clean persistence using `data/` folder.

### Why pgAdmin is not directly published to the internet

* pgAdmin is reachable only through **Nginx**, not via a public port.
* pgAdmin is mapped to **localhost only** on the VPS, so it cannot be reached externally.

### Critical constraint: Nginx runs in `network_mode: host`

* When Nginx runs with `network_mode: host`, it **cannot use Docker DNS**.
* That means `proxy_pass http://infra-pgadmin:80;` will fail with:

  * `host not found in upstream`.

✅ **Solution:** expose pgAdmin on `127.0.0.1:<port>` and proxy Nginx to localhost.

---

## 1) Prerequisites

### DNS

* `pgadmin.marin.cr` must have an **A record** pointing to the VPS public IP.

### Firewall (UFW)

* Must allow:

  * `22/tcp` (SSH)
  * `80/tcp` (HTTP)
  * `443/tcp` (HTTPS)
  * `5432/tcp` (Postgres public access — high risk)

Verify:

```bash
ufw status verbose
```

---

## 2) Create the application folder

We follow your rule:
**One app = one folder = one Compose file**

```bash
mkdir -p /opt/infra/apps/postgres/{data,secrets}
cd /opt/infra/apps/postgres
```

> Note: pgAdmin storage uses a **named Docker volume** (not a host folder) to avoid permissions issues.

---

## 3) Create the `.env` file (secrets)

```bash
nano /opt/infra/apps/postgres/.env
```

Example:

```env
POSTGRES_DB=appdb
POSTGRES_USER=appuser
POSTGRES_PASSWORD=CHANGE_ME_LONG_RANDOM

PGADMIN_DEFAULT_EMAIL=oscar@marin.cr
PGADMIN_DEFAULT_PASSWORD=CHANGE_ME_LONG_RANDOM
```

✅ **Lesson learned:** `PGADMIN_DEFAULT_EMAIL` and `PGADMIN_DEFAULT_PASSWORD` are used **only on first initialization**. After that, pgAdmin stores users in its internal DB.

---

## 4) Create the Docker Compose file (Postgres + pgAdmin)

```bash
nano /opt/infra/apps/postgres/compose.yml
```

Use this working [compose](https://github.com/marinoscar/marin-server-infra/blob/ebd91bdb51721e0a7600d8e4c5373c2850f1c29e/apps/postgres/compose.yml)



✅ **Lessons learned:**

* pgAdmin bind-mounting to `./pgadmin-data` caused:

  * `Failed to create the directory /var/lib/pgadmin/sessions: Permission denied`
* Using a named volume `pgadmin_data` fixes it permanently.
* Binding pgAdmin to `127.0.0.1:5050` is required because Nginx is in host mode.

---

## 5) Start the stack and verify

```bash
cd /opt/infra/apps/postgres
docker compose up -d
```

Verify:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Expected:

* `infra-postgres` shows `0.0.0.0:5432->5432/tcp`
* `infra-pgadmin` shows `127.0.0.1:5050->80/tcp`

Verify pgAdmin locally:

```bash
curl -I http://127.0.0.1:5050/login
```

Expected: `200 OK`.

---

## 6) Configure Nginx reverse proxy (HTTP first)

### 6.1 Create Nginx vhost (HTTP-only)

```bash
nano /opt/infra/proxy/nginx/conf.d/pgadmin.marin.cr.conf
```

**HTTP-only config (works with host-mode Nginx):**

[pgadmin.marin.cr.conf](https://github.com/marinoscar/marin-server-infra/blob/ebd91bdb51721e0a7600d8e4c5373c2850f1c29e/proxy/nginx/conf.d/pgadmin.marin.cr.conf)


Reload Nginx:

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

Test:

```bash
curl -I http://pgadmin.marin.cr/login
```

Expected: `200 OK`.

✅ **Lesson learned:**

* If Nginx points to `infra-pgadmin` while running in host mode, it will fail with `host not found in upstream`.

---

## 7) Enable HTTPS with Let’s Encrypt (Certbot webroot)

### 7.1 Ensure folders exist

```bash
mkdir -p /opt/infra/proxy/{letsencrypt,webroot}
```

### 7.2 Issue the cert (one-off certbot container)

```bash
docker run --rm \
  -v /opt/infra/proxy/letsencrypt:/etc/letsencrypt \
  -v /opt/infra/proxy/webroot:/var/www/certbot \
  certbot/certbot:latest certonly \
  --webroot -w /var/www/certbot \
  -d pgadmin.marin.cr \
  --email oscar@marin.cr \
  --agree-tos \
  --no-eff-email
```

Verify:

```bash
ls -la /opt/infra/proxy/letsencrypt/live/pgadmin.marin.cr/
```


Test:

```bash
curl -I https://pgadmin.marin.cr/login
```

Expected: `200 OK`.

✅ **Lesson learned:**

* Nginx may warn that `listen ... http2` is deprecated. The modern pattern used above is:

  * `listen 443 ssl;` + `http2 on;`

---

## 8) pgAdmin login + lockout recovery

### 8.1 Why login credentials “don’t update”

* `PGADMIN_DEFAULT_EMAIL` / `PGADMIN_DEFAULT_PASSWORD` are used **only at first init**.
* After that, pgAdmin stores user accounts in its internal DB (in the Docker volume).

### 8.2 If you get locked out

pgAdmin can lock the account after failed attempts (you saw: `0 more attempt remaining`).

**Fast reset approach (recommended early on):**

1. Update `.env` with the desired password
2. Stop stack
3. Remove the pgAdmin volume
4. Start stack

Commands:

```bash
nano /opt/infra/apps/postgres/.env

cd /opt/infra/apps/postgres
docker compose down

docker volume ls | grep pgadmin
# volume name is usually: postgres_pgadmin_data

docker volume rm postgres_pgadmin_data

docker compose up -d
```

✅ **Lesson learned:** After resetting pgAdmin volume, Nginx may return **502 Bad Gateway** until it reconnects.

### 8.3 Fixing 502 after reset

If pgAdmin was recreated and Nginx returns **502**:

```bash
docker restart proxy-nginx
```

This worked immediately in practice.

---

## 9) PostgreSQL public access notes (important)

You intentionally opened:

* `0.0.0.0:5432->5432/tcp`

This means Postgres is reachable from the internet and will be constantly scanned/bruteforced.

**Minimum recommended hardening (follow-up phase):**

* Enable TLS on Postgres
* Force SSL-only via `pg_hba.conf` (`hostnossl reject`, `hostssl ... scram-sha-256`)
* Consider IP allowlisting if possible

(These hardening steps can be added in a later doc once pgAdmin is stable.)

---

## 10) Operational commands

### Start/stop Postgres stack

```bash
cd /opt/infra/apps/postgres
docker compose up -d

docker compose down
```

### Logs

```bash
docker logs --tail 100 infra-postgres
docker logs --tail 100 infra-pgadmin
```

### Verify pgAdmin backend (host)

```bash
curl -I http://127.0.0.1:5050/login
```

### Verify pgAdmin public URL

```bash
curl -I https://pgadmin.marin.cr/login
```

### Nginx validate/reload

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

### Quick fix if 502 happens after container recreation

```bash
docker restart proxy-nginx
```

---

## 11) Certificate renewal

Create renewal script:

```bash
nano /opt/infra/shared/renew-pgadmin-cert.sh
```

```bash
#!/usr/bin/env bash
set -e

docker run --rm \
  -v /opt/infra/proxy/letsencrypt:/etc/letsencrypt \
  -v /opt/infra/proxy/webroot:/var/www/certbot \
  certbot/certbot:latest renew --webroot -w /var/www/certbot

docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

Make executable:

```bash
chmod +x /opt/infra/shared/renew-pgadmin-cert.sh
```

Run manually:

```bash
/opt/infra/shared/renew-pgadmin-cert.sh
```

Add cron:

```bash
crontab -e
```

Add:

```cron
17 3 * * * /opt/infra/shared/renew-pgadmin-cert.sh >> /opt/infra/shared/renew-pgadmin-cert.log 2>&1
```

---

## 12) Troubleshooting quick reference

### A) pgAdmin permission error: `/var/lib/pgadmin/sessions` denied

**Cause:** host bind mount permissions.
**Fix:** use Docker named volume `pgadmin_data`.

### B) Nginx error: `host not found in upstream "infra-pgadmin"`

**Cause:** Nginx is in `network_mode: host` and cannot resolve Docker DNS.
**Fix:** proxy to `http://127.0.0.1:5050` instead.

### C) pgAdmin login env vars don’t work

**Cause:** env vars only apply on first initialization.
**Fix:** reset volume (`docker volume rm postgres_pgadmin_data`).

### D) 502 Bad Gateway after reset

**Fix:** restart Nginx container:

```bash
docker restart proxy-nginx
```

---

## Current final state (known-good)

* Postgres: **public** on `:5432`
* pgAdmin: internal on `127.0.0.1:5050` (not public)
* Nginx: routes `https://pgadmin.marin.cr` → `http://127.0.0.1:5050`
* TLS: Let’s Encrypt cert at `/opt/infra/proxy/letsencrypt/live/pgadmin.marin.cr/`

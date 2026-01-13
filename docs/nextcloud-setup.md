# Nextcloud Setup (Docker, Postgres, S3, Nginx Reverse Proxy, Let’s Encrypt)

This runbook documents the **final working** installation of **Nextcloud** on the VPS using the same platform conventions as `/opt/infra`.

It is intentionally detailed and includes the **exact lessons learned** to avoid repeated failures.

---

## Goals (Final State)

* **Nextcloud** runs in Docker
* **PostgreSQL** is hosted **outside** the Nextcloud stack (existing server), reachable as `pgadmin.marin.cr`

  * DB user: `admin`
  * DB name: `nextcloud`
* **S3** is used for **primary storage** (user files)
* **Nginx reverse proxy** runs in Docker under `/opt/infra/proxy`
* Nextcloud is reachable at:

  * `https://cloud.marin.cr`
* Certificates issued and renewed using **Certbot webroot** method

---

## Assumptions / Prerequisites

### Server prerequisites

* Ubuntu VPS with **root** SSH access
* Docker Engine + Docker Compose plugin installed
* Reverse proxy stack exists at `/opt/infra/proxy` and is running
* Shared Docker network `proxy` exists
* UFW allows ports: `22`, `80`, `443`, and `5432` (PostgreSQL exposure should be hardened)

### DNS prerequisites

* `cloud.marin.cr` A record points to the VPS public IP

### Operator conventions (must follow)

* Operate as **root** (intentionally)
* Use **nano** for editing
* **Git-first** for infra config (no secrets committed)
* **No secrets in Git** (`.env` always ignored)

---

## Folder layout

Create the app folder:

```
/opt/infra/apps/nextcloud
  compose.yml
  .env              # secrets (ignored)
  data/             # persistent nextcloud volume (ignored)
  backups/          # local backups (ignored)
```

---

## Step 1 — Create the Nextcloud app folder

```bash
mkdir -p /opt/infra/apps/nextcloud
cd /opt/infra/apps/nextcloud
```

Create `.gitignore`:

```bash
nano .gitignore
```

```gitignore
.env
data/
backups/
```

---

## Step 2 — Create the `.env` (secrets only)

```bash
nano /opt/infra/apps/nextcloud/.env
```

Example:

```env
# ---- Nextcloud admin ----
NEXTCLOUD_ADMIN_USER=marinoscar
NEXTCLOUD_ADMIN_PASSWORD=CHANGE_ME

# ---- PostgreSQL (external) ----
POSTGRES_HOST=pgadmin.marin.cr
POSTGRES_DB=nextcloud
POSTGRES_USER=admin
POSTGRES_PASSWORD=CHANGE_ME

# ---- S3 Primary Storage (official docker variables) ----
OBJECTSTORE_S3_BUCKET=marinapp-nextcloud
OBJECTSTORE_S3_KEY=CHANGE_ME
OBJECTSTORE_S3_SECRET=CHANGE_ME
OBJECTSTORE_S3_REGION=us-east-1
OBJECTSTORE_S3_HOST=s3.amazonaws.com
OBJECTSTORE_S3_SSL=true
OBJECTSTORE_S3_PORT=443
OBJECTSTORE_S3_AUTOCREATE=true
OBJECTSTORE_S3_PATHSTYLE=false

# ---- Redis ----
REDIS_HOST=redis
```

**Important:**

* **Do not paste secrets into chat**. If you did, treat them as compromised and rotate.
* Any password containing `!` will trigger Bash history expansion in some shells—use single quotes or disable history expansion (`set +H`) when running commands that include such secrets.

---

## Step 3 — Create `compose.yml`

```bash
nano /opt/infra/apps/nextcloud/compose.yml
```

[compose.yml](https://github.com/marinoscar/marin-server-infra/blob/eea189568d56c0ebbc631e2ca57814c18b90e191/apps/nextcloud/compose.yml)

### Why we use localhost port mapping

* Avoid binding port 80 for apps (reserved for proxy)
* Nextcloud is reachable only on the host loopback
* Nginx reverse proxy handles all internet traffic

---

## Step 4 — Create AWS S3 bucket (must exist first)

### Required answers from earlier troubleshooting

1. **Bucket must exist before install** (Nextcloud does not create the bucket)
2. “Block all public access” should be enabled
3. Start with bucket versioning **disabled** (enable later only with lifecycle rules)

**Bucket type:** General Purpose

**Permissions:** the IAM principal used by Nextcloud must allow at minimum:

* list bucket
* get/put/delete objects

---

## Step 5 — Create PostgreSQL DB (must exist first)

Nextcloud creates **tables**, but does **not** create the **database**.

Ensure DB exists:

* Host: `pgadmin.marin.cr`
* Database: `nextcloud`
* User: `admin`

If you need to reset a failed install, **drop and recreate** the DB (recommended), or drop and recreate schema.

---

## Step 6 — Start the stack

```bash
cd /opt/infra/apps/nextcloud
docker compose pull
docker compose up -d
```

### Test: confirm env vars are injected

```bash
docker exec -it nextcloud env | egrep 'OBJECTSTORE_S3_|POSTGRES_|REDIS_'
```

### Test: confirm local reachability

```bash
curl -I http://127.0.0.1:8082
curl -s http://127.0.0.1:8082 | head -n 20
```

---

## Step 7 — If Nextcloud says “Configuration was not read or initialized correctly”

### What it means

* Nextcloud is running, but **install did not complete**
* `config/config.php` may be empty or invalid
* `occ status` will show `installed: false`

### Confirm

```bash
docker exec -u www-data -it nextcloud php occ status
```

### Fix (deterministic): run install via `occ`

If UI install loops or fails, run:

```bash
set +H

docker exec -u www-data -it nextcloud php occ maintenance:install \
  --database "pgsql" \
  --database-host "pgadmin.marin.cr" \
  --database-name "nextcloud" \
  --database-user "admin" \
  --database-pass 'YOUR_DB_PASSWORD' \
  --admin-user "YOUR_ADMIN_USER" \
  --admin-pass 'YOUR_ADMIN_PASSWORD'

set -H
```

**Key learning:**

* If your password contains `!`, you must single-quote it or disable history expansion (`set +H`), otherwise you’ll see `event not found`.

### Verify installed

```bash
docker exec -u www-data -it nextcloud php occ status
```

Expected:

* `installed: true`

---

## Step 8 — Reverse proxy config for `cloud.marin.cr`

### File

```bash
nano /opt/infra/proxy/nginx/conf.d/cloud.marin.cr.conf
```

live version: [cloud.marin.cr.conf](https://github.com/marinoscar/marin-server-infra/blob/eea189568d56c0ebbc631e2ca57814c18b90e191/proxy/nginx/conf.d/cloud.marin.cr.conf)

### HTTP (port 80) block (ACME + redirect)

```nginx
server {
    listen 80;
    listen [::]:80;

    server_name cloud.marin.cr;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}
```

### HTTPS (port 443) block

Because Nextcloud is bound to `127.0.0.1:8082` on the host, the proxy container must reach the host via `host.docker.internal`.

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name cloud.marin.cr;

    ssl_certificate     /etc/letsencrypt/live/cloud.marin.cr/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/cloud.marin.cr/privkey.pem;

    client_max_body_size 10G;
    proxy_read_timeout 3600;

    location / {
        proxy_pass http://host.docker.internal:8082;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```

---

## Step 9 — Enable host gateway routing for proxy container

Edit proxy compose:

```bash
nano /opt/infra/proxy/compose.yml
```

Add under the `nginx:` service:

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

Recreate proxy:

```bash
cd /opt/infra/proxy
docker compose up -d --force-recreate
```

Reload Nginx:

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

---

## Step 10 — Issue Let’s Encrypt cert (webroot)

```bash
docker run --rm \
  -v /opt/infra/proxy/letsencrypt:/etc/letsencrypt \
  -v /opt/infra/proxy/webroot:/var/www/certbot \
  certbot/certbot \
  certonly \
  --webroot \
  -w /var/www/certbot \
  -d cloud.marin.cr \
  --agree-tos \
  --email oscar@marin.cr \
  --non-interactive
```

Verify:

```bash
ls -l /opt/infra/proxy/letsencrypt/live/cloud.marin.cr/
```

---

## Step 11 — Nextcloud reverse proxy settings (fix admin warnings)

### 11.1 Trusted domain

If you see “Access through untrusted domain”, add `cloud.marin.cr`:

```bash
docker exec -u www-data -it nextcloud php occ config:system:set trusted_domains 0 --value="cloud.marin.cr"
```

Verify:

```bash
docker exec -u www-data -it nextcloud php occ config:system:get trusted_domains
```

### 11.2 Trusted proxies (must be IP/CIDR, not hostname)

If you see warning about `trusted_proxies`, set it to the **Docker proxy network subnet**.

Find subnet:

```bash
docker network inspect proxy --format '{{(index .IPAM.Config 0).Subnet}}'
```

Example from this setup:

* `172.18.0.0/16`

Set it:

```bash
docker exec -u www-data -it nextcloud php occ config:system:delete trusted_proxies || true
docker exec -u www-data -it nextcloud php occ config:system:set trusted_proxies 0 --value="172.18.0.0/16"
```

### 11.3 Overwrite host/protocol

```bash
docker exec -u www-data -it nextcloud php occ config:system:set overwritehost --value="cloud.marin.cr"
docker exec -u www-data -it nextcloud php occ config:system:set overwriteprotocol --value="https"
docker exec -u www-data -it nextcloud php occ config:system:set forwarded_for_headers 0 --value="HTTP_X_FORWARDED_FOR"
```

Restart Nextcloud:

```bash
cd /opt/infra/apps/nextcloud
docker compose restart nextcloud
```

---

## Step 12 — Fix integrity check error for extra backup files

If the Security & Setup warnings show integrity issues like:

* `EXTRA_FILE config-backup/config.php`

It means you placed a backup folder under `/var/www/html` (the mounted volume).

Move backups out of the Nextcloud web root:

```bash
mkdir -p /opt/infra/apps/nextcloud/backups
mv /opt/infra/apps/nextcloud/data/config-backup /opt/infra/apps/nextcloud/backups/ || true
```

Re-run the integrity check.

---

## Step 13 — Final validation checklist

### 13.1 Nextcloud installed

```bash
docker exec -u www-data -it nextcloud php occ status
```

Expect:

* `installed: true`

### 13.2 Local app reachable

```bash
curl -I http://127.0.0.1:8082
```

### 13.3 Proxy works

```bash
curl -I http://cloud.marin.cr
curl -I https://cloud.marin.cr
```

Expect:

* HTTP returns `301` to HTTPS
* HTTPS returns `200` or `302`

### 13.4 Nginx config validation

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

### 13.5 S3 is actually receiving objects

Upload a test file in the UI, then confirm the bucket has objects (from any machine with AWS CLI configured):

```bash
aws s3 ls s3://marinapp-nextcloud --recursive | head -n 30
```

---

## Certificate renewal (automation)

Create renewal script:

```bash
nano /opt/infra/shared/renew-cloud-certs.sh
```

```bash
#!/bin/bash

docker run --rm \
  -v /opt/infra/proxy/letsencrypt:/etc/letsencrypt \
  -v /opt/infra/proxy/webroot:/var/www/certbot \
  certbot/certbot renew --quiet

docker exec proxy-nginx nginx -s reload
```

Make executable:

```bash
chmod +x /opt/infra/shared/renew-cloud-certs.sh
```

Add cron:

```bash
crontab -e
```

```cron
0 3 * * * /opt/infra/shared/renew-cloud-certs.sh >> /opt/infra/shared/renew-cloud-certs.log 2>&1
```

Test:

```bash
/opt/infra/shared/renew-cloud-certs.sh
tail -n 50 /opt/infra/shared/renew-cloud-certs.log
```

---

## Known pitfalls (lessons learned)

1. **S3 bucket must exist first** (Nextcloud won’t create it)
2. **Postgres database must exist first** (Nextcloud won’t create it)
3. Compose reads `.env` for substitution, but you must **explicitly inject env vars** into the container via `environment:`
4. `trusted_proxies` must be **IP/CIDR**, not container names
5. Passwords containing `!` will break shell commands unless quoted or `set +H`
6. The web installer can loop; the most deterministic install is:

   * `occ maintenance:install ...`
7. Do not leave backup folders inside `/var/www/html` (integrity checks will flag them)

---

## Git checkpoint (infra only)

Commit only non-secret config:

```bash
cd /opt/infra
git add apps/nextcloud/compose.yml proxy/nginx/conf.d/cloud.marin.cr.conf
git commit -m "Add Nextcloud stack with Postgres, S3, and reverse proxy"
git push
```

Never commit `.env`, `data/`, `backups/`, or certificates.
